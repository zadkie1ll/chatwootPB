# A verified phone joins messenger identities to one ownership and CRM record.
# Ambiguous existing contacts require an explicit resolution instead of a merge.
class Corporate::ChannelContact
  def self.find(account, phone)
    return if phone.blank?

    ids = ChannelIdentity.where(account: account, verified_phone: phone).distinct.limit(2).pluck(:contact_id)
    identified = ChannelIdentity.where(account: account).select(:contact_id)
    ids |= account.contacts.where(id: identified, phone_number: phone).limit(2).pluck(:id)
    account.contacts.find(ids.first) if ids.one?
  end

  def self.refresh_crm(account, conversation, assign_owner: false)
    return unless Corporate.crm_enabled?(account)
    return unless Corporate::Channels.crm_enabled?(Corporate::Channels.for_conversation(conversation))

    link = CorporateCrmLink.find_by(account: account, contact_id: conversation.contact_id)
    return unless link&.sync_state == 'applied' && link.conversation_id != conversation.id

    ownership = CustomerOwnership.find_by!(account: account, contact_id: conversation.contact_id)
    link.conversation = conversation
    Corporate::CrmLinkService.queue!(link, ownership: ownership, actor: link.actor, assign_owner: assign_owner)
  end
end
