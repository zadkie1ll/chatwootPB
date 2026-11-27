class Corporate::StaffService
  class CleanupPending < StandardError; end

  def initialize(account:, actor:)
    @account = account
    @actor = actor
    raise Pundit::NotAuthorizedError unless Corporate.role(account, actor) == 'supervisor'
  end

  def create(attributes)
    attributes = attributes.dup
    bitrix_user_id = attributes.delete(:bitrix_user_id)
    if bitrix_user_id.present?
      employee = Corporate::StaffCrm.new(@account).employee(bitrix_user_id)
      attributes = attributes.merge(name: employee.fetch('name'), email: employee.fetch('email'))
    end
    validate_password!(attributes[:password])

    @account.with_lock do
      user = User.new(attributes)
      user.skip_confirmation!
      user.save!
      AccountUser.create!(account: @account, user: user, role: :agent)
      CorporateMembership.create!(account: @account, user: user, role: 'manager')
      Corporate::StaffCrm.new(@account).map!(user, bitrix_user_id) if bitrix_user_id.present?
      user
    end
  end

  def update(user_id, attributes)
    attributes = attributes.dup
    bitrix_user_id = attributes.delete(:bitrix_user_id)
    Corporate::StaffCrm.new(@account).employee(bitrix_user_id) if bitrix_user_id.present?
    validate_password!(attributes[:password]) if attributes.key?(:password)

    @account.with_lock do
      member = CorporateMembership.find_by!(account: @account, user_id: user_id, role: 'manager')
      user = member.user
      revoke = attributes[:password].present? || (attributes.key?(:email) && attributes[:email] != user.email)
      user.skip_reconfirmation!
      user.update!(attributes)
      Corporate::StaffCrm.new(@account).map!(user, bitrix_user_id) if bitrix_user_id.present?
      revoke_sessions(user) if revoke
      user
    end
  end

  def enable(user_id)
    @account.with_lock do
      member = CorporateMembership.find_by!(account: @account, user_id: user_id, role: 'manager')
      raise CleanupPending if !member.active? && CustomerOwnership.exists?(account: @account, owner_id: user_id)

      member.update!(active: true)
      member
    end
  end

  def disable(user_id)
    @account.with_lock do
      membership = CorporateMembership.find_by!(account: @account, user_id: user_id, role: 'manager')
      return membership unless membership.active?

      was_absent = membership.chats_shared_while_absent?
      membership.update!(active: false, chats_shared_while_absent: false)
      revoke_sessions(membership.user)
      ActiveRecord.after_all_transactions_commit do
        Corporate::SharingChangedJob.perform_later(@account.id, true) if was_absent
        Corporate::DisabledStaffCleanupJob.perform_later(@account.id, membership.user_id, @actor.id)
      end
      membership
    end
  end

  private

  def validate_password!(password)
    raise ArgumentError unless password.is_a?(String) && password.length.between?(12, 128)
  end

  def revoke_sessions(user)
    old_stream = Corporate.stream(@account.id, user.id)
    user.update!(tokens: {}, pubsub_token: SecureRandom.base58(24))
    user.access_token&.regenerate_token
    account_id = @account.id
    ActiveRecord.after_all_transactions_commit do
      ActionCable.server.broadcast(old_stream, { event: 'corporate.access_changed', data: { account_id: account_id } })
    end
  end
end
