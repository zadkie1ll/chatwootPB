# Explicit CRM binding can identify a previously anonymous chat in another channel.
# Preserve the old contact/audit, and move its identities and conversations only
# when the actor can already read the destination customer.
class Corporate::CrmIdentityMerge
  def initialize(account:, actor:)
    @account = account
    @actor = actor
  end

  def perform(conversation, result)
    return unless result['found']

    existing = CorporateCrmLink.find_by(account: @account, external_deal_id: result.fetch('deal_id'),
                                        entity_type: result.fetch('entity_type', 'deal'))
    return unless existing && existing.contact_id != conversation.contact_id

    source = conversation.contact
    target = Corporate.contacts(@account, @actor).find(existing.contact_id)
    validate_merge!(source, target, existing)
    move_records(source, target)
    retire_source(source, target)
    conversation.reload
  end

  private

  def validate_merge!(source, target, existing)
    link = CorporateCrmLink.find_by(account: @account, contact: source)
    raise Corporate::CrmClient::Error, 'crm_binding_conflict' if link&.external_deal_id.present?
    raise Corporate::DispatchInProgress if existing.dispatch_unresolved?

    validate_deliveries!(source)
    validate_identities!(source, target)
  end

  def validate_deliveries!(source)
    conversations = @account.conversations.where(contact: source).select(:id)
    messages = @account.messages.where(conversation_id: conversations).select(:id)
    deliveries = CorporateDelivery.where(account: @account, message_id: messages, state: %w[pending in_flight unknown])
    raise Corporate::DispatchInProgress if deliveries.exists?
  end

  def validate_identities!(source, target)
    keys = ChannelIdentity.where(account: @account, contact: target).pluck(:channel, :external_account_id)
    conflict = ChannelIdentity.where(account: @account, contact: source).any? do |identity|
      keys.include?([identity.channel, identity.external_account_id])
    end
    raise Corporate::CrmClient::Error, 'crm_binding_conflict' if conflict
  end

  def move_records(source, target)
    ChannelIdentity.where(account: @account, contact: source).find_each { |identity| identity.update!(contact: target) }
    source.contact_inboxes.find_each { |record| record.update!(contact: target) }
    owner_id = CustomerOwnership.find_by!(account: @account, contact: target).owner_id
    @account.conversations.where(contact: source).find_each { |record| record.update!(contact: target, assignee_id: owner_id) }
    @account.messages.where(sender_type: 'Contact', sender_id: source.id).find_each { |message| message.update!(sender: target) }
  end

  def retire_source(source, target)
    ownership = CustomerOwnership.find_by!(account: @account, contact: source)
    previous_owner = ownership.owner_id
    ownership.update!(owner: nil, assigned_at: nil, shared_unidentified: false)
    AssignmentAudit.create!(account: @account, contact: source, actor: @actor, old_owner_id: previous_owner, new_owner_id: nil,
                            reason: "channel_identity_merged_into_#{target.id}", source: 'user',
                            correlation_id: SecureRandom.uuid, assignment_version: ownership.lock_version)
    account_id = @account.id
    ActiveRecord.after_all_transactions_commit do
      CorporateMembership.where(account_id: account_id, role: 'manager', active: true).find_each do |member|
        Corporate::RevocationJob.perform_later(account_id, member.user_id)
      end
    end
  end
end
