class Corporate::CrmLookupJob < ApplicationJob
  queue_as :default
  retry_on Corporate::CrmClient::Error, wait: :polynomially_longer, attempts: 8

  def perform(account_id, conversation_id, actor_id, assignment_version)
    return unless Corporate.crm_enabled?

    account = Account.find(account_id)
    return unless Corporate.crm_enabled?(account)

    conversation = account.conversations.find(conversation_id)
    actor = account.users.find(actor_id)
    ownership = CustomerOwnership.find_by!(account: account, contact_id: conversation.contact_id)
    return unless ownership.lock_version == assignment_version && Corporate.can_read?(account, actor, conversation)

    phone = ChannelIdentity.find_by!(account: account, contact_id: conversation.contact_id, channel: 'telegram').verified_phone
    return if phone.blank?

    Corporate::CrmLinkService.new(account: account, actor: actor).bind(
      conversation: conversation, phone: phone, source: 'outbound', expected_version: assignment_version
    )
  rescue ActiveRecord::RecordNotFound, Pundit::NotAuthorizedError
    # A transfer or disabled employee makes this queued lookup obsolete.
    nil
  end
end
