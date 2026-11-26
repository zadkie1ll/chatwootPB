class Corporate::OwnershipService
  def initialize(account:, actor:)
    @account = account
    @actor = actor
  end

  def claim(contact:, reason: 'outbound_claim', correlation_id: SecureRandom.uuid)
    raise Pundit::NotAuthorizedError unless Corporate.role(@account, @actor) == 'manager'

    @account.with_lock do
      contact = @account.contacts.find(contact.id)
      ownership = CustomerOwnership.find_or_create_by!(account: @account, contact: contact)
      raise ActiveRecord::RecordNotFound if ownership.owner_id.present? && ownership.owner_id != @actor.id

      change_owner(ownership, @actor.id, reason, correlation_id) if ownership.owner_id.nil? || ownership.shared_unidentified?
      ownership
    end
  end

  def transfer(contact:, owner_id:, reason:, correlation_id: SecureRandom.uuid)
    raise Pundit::NotAuthorizedError unless Corporate.role(@account, @actor) == 'supervisor'

    @account.with_lock do
      contact = @account.contacts.find(contact.id)
      ownership = CustomerOwnership.find_or_create_by!(account: @account, contact: contact)
      change_owner(ownership, owner_id, reason, correlation_id) if ownership.owner_id != owner_id || ownership.shared_unidentified?
      ownership
    end
  end

  # Called only by trusted CRM jobs/internal service endpoints, never user controllers.
  def sync_from_crm(contact:, owner_id:, reason: 'crm_inbound_matched')
    raise Pundit::NotAuthorizedError unless @actor.nil?

    @account.with_lock do
      contact = @account.contacts.find(contact.id)
      ownership = CustomerOwnership.find_or_create_by!(account: @account, contact: contact)
      if ownership.owner_id != owner_id || ownership.shared_unidentified?
        change_owner(ownership, owner_id, reason, SecureRandom.uuid, source: 'bitrix24')
      end
      ownership
    end
  end

  private

  def change_owner(ownership, owner_id, reason, correlation_id, source: 'user')
    crm_link = CorporateCrmLink.find_by(account: @account, contact_id: ownership.contact_id)
    sync_crm = sync_crm_owner?(crm_link, owner_id, reason, source)
    validate_crm_assignment!(crm_link, owner_id, sync_crm)
    cancel_pending_deliveries!(ownership)
    old_owner_id = ownership.owner_id
    was_shared = shared_before_transfer?(ownership)
    ownership.update!(owner_id: owner_id, assigned_at: owner_id.present? ? Time.current : nil, shared_unidentified: false)
    @account.conversations.where(contact_id: ownership.contact_id).find_each do |conversation|
      conversation.update!(assignee_id: owner_id)
    end
    AssignmentAudit.create!(
      account: @account, contact: ownership.contact, actor: @actor,
      old_owner_id: old_owner_id, new_owner_id: owner_id, reason: reason,
      correlation_id: correlation_id, assignment_version: ownership.lock_version, source: source
    )
    Corporate::CrmLinkService.queue!(crm_link, ownership: ownership, actor: @actor) if sync_crm
    revoke_shared_access(owner_id) if was_shared
    # No contact details go to the previous owner; force a fresh authorised view.
    return unless old_owner_id.present? && old_owner_id != owner_id

    ActiveRecord.after_all_transactions_commit { Corporate::RevocationJob.perform_later(@account.id, old_owner_id) }
  end

  def shared_before_transfer?(ownership)
    ownership.shared_unidentified? || Corporate::Visibility.absent_members(@account).exists?(user_id: ownership.owner_id)
  end

  def sync_crm_owner?(link, owner_id, reason, source)
    Corporate.crm_enabled?(@account) && link&.external_deal_id.present? && owner_id.present? && reason != 'crm_linked' && source == 'user'
  end

  def validate_crm_assignment!(link, owner_id, sync_crm)
    raise Corporate::DispatchInProgress if link&.dispatch_unresolved?
    return unless sync_crm
    return if CorporateCrmEmployee.exists?(account: @account, user_id: owner_id)

    raise Corporate::CrmClient::Error, 'crm_employee_not_mapped'
  end

  def cancel_pending_deliveries!(ownership)
    conversations = @account.conversations.where(contact_id: ownership.contact_id).select(:id)
    messages = @account.messages.where(conversation_id: conversations).select(:id)
    active = CorporateDelivery.where(account: @account, message_id: messages)
    raise Corporate::DispatchInProgress if active.exists?(state: %w[in_flight unknown])

    active.where(state: 'pending').find_each { |delivery| delivery.set_state!('cancelled', error_code: 'ownership_changed') }
  end

  def revoke_shared_access(owner_id)
    account_id = @account.id
    ActiveRecord.after_all_transactions_commit do
      CorporateMembership.where(account_id: account_id, role: 'manager', active: true).where.not(user_id: owner_id).find_each do |member|
        Corporate::RevocationJob.perform_later(account_id, member.user_id)
      end
    end
  end
end
