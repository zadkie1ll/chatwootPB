class Corporate::StaffService
  def initialize(account:, actor:)
    @account = account
    @actor = actor
    raise Pundit::NotAuthorizedError unless Corporate.role(account, actor) == 'supervisor'
  end

  def create(attributes)
    raise ArgumentError unless attributes.fetch(:password, '').length.between?(12, 128)

    @account.with_lock do
      user = User.new(attributes)
      user.skip_confirmation!
      user.save!
      AccountUser.create!(account: @account, user: user, role: :agent)
      CorporateMembership.create!(account: @account, user: user, role: 'manager')
      user
    end
  end

  def disable(user_id)
    @account.with_lock do
      membership = CorporateMembership.find_by!(account: @account, user_id: user_id, role: 'manager')
      old_stream = Corporate.stream(@account.id, membership.user_id)
      membership.update!(active: false)
      membership.user.update!(tokens: {}, pubsub_token: SecureRandom.base58(24))
      membership.user.access_token&.regenerate_token
      ActiveRecord.after_all_transactions_commit do
        ActionCable.server.broadcast(old_stream, { event: 'corporate.access_changed', data: { account_id: @account.id } })
        Corporate::DisabledStaffCleanupJob.perform_later(@account.id, membership.user_id, @actor.id)
      end
      membership
    end
  end
end
