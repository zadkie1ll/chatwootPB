class Corporate::CrmInboundLookupJob < ApplicationJob
  queue_as :default
  retry_on Corporate::CrmClient::Error, wait: :polynomially_longer, attempts: 8
  retry_on Corporate::DispatchInProgress, wait: 10.seconds, attempts: 10

  def perform(account_id, conversation_id)
    return unless Corporate.crm_enabled?

    account = Account.find(account_id)
    return unless Corporate.crm_enabled?(account)

    conversation = account.conversations.find(conversation_id)
    phone = conversation.contact.phone_number
    return if phone.blank?
    return if linked?(account, conversation)

    result = Corporate::CrmClient.new.call('resolve', { phone: phone })
    linked = result.fetch('found') && link_inbound(account, conversation, result, phone)
    Corporate::InboundIntake.new(account).share(conversation.contact) unless linked
  end

  private

  def link_inbound(account, conversation, result, phone)
    account.with_lock do
      ownership = CustomerOwnership.find_by!(account: account, contact_id: conversation.contact_id)
      return unless unassigned?(account, conversation, ownership, result)

      mapping = CorporateCrmEmployee.find_by(account: account, external_user_id: result.fetch('assigned_user_id'))
      return unless mapping && Corporate.role(account, mapping.user) == 'manager'

      ownership = Corporate::OwnershipService.new(account: account, actor: nil).sync_from_crm(
        contact: conversation.contact, owner_id: mapping.user_id
      )
      link = CorporateCrmLink.find_or_initialize_by(account: account, contact: conversation.contact)
      link.assign_attributes(conversation: conversation,
                             actor: mapping.user, external_deal_id: result.fetch('deal_id'),
                             entity_type: result.fetch('entity_type', 'deal'), deal_title: result.fetch('title'),
                             deal_url: result.fetch('deal_url'), phone: phone, phone_source: Corporate::Channels.for_conversation(conversation))
      Corporate::CrmLinkService.queue!(link, ownership: ownership, actor: mapping.user, assign_owner: false)
      true
    end
  end

  def linked?(account, conversation)
    link = CorporateCrmLink.find_by(account: account, contact_id: conversation.contact_id)
    link && (link.external_deal_id.present? || link.dispatch_unresolved?)
  end

  def unassigned?(account, conversation, ownership, result)
    return false if ownership.owner_id.present?
    return false if linked?(account, conversation)

    !CorporateCrmLink.exists?(account: account, external_deal_id: result.fetch('deal_id'), entity_type: result.fetch('entity_type', 'deal'))
  end
end
