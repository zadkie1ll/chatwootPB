# Conservative rollout: never publish an owned, previously owned or CRM-linked client.
class Corporate::SharedIntakeBackfill
  def initialize(account)
    @account = account
  end

  def perform
    return 0 unless Corporate.shared_intake_enabled?(@account)

    count = 0
    @account.with_lock do
      eligible.limit(1000).find_each do |ownership|
        ownership.update!(shared_unidentified: true)
        count += 1
      end
    end
    if count.positive?
      CorporateMembership.where(account: @account, role: 'manager', active: true).find_each do |member|
        Corporate::RevocationJob.perform_later(@account.id, member.user_id)
      end
    end
    count
  end

  private

  def eligible
    previously_owned = AssignmentAudit.where(account: @account).where.not(new_owner_id: nil).select(:contact_id)
    linked = CorporateCrmLink.where(account: @account).select(:contact_id)
    CustomerOwnership.where(account: @account, owner_id: nil, shared_unidentified: false)
                     .where(contact_id: unknown_contacts).where(contact_id: incoming_contacts)
                     .where.not(contact_id: previously_owned).where.not(contact_id: linked)
                     .where.not(contact_id: active_delivery_contacts)
  end

  def unknown_contacts
    identities = ChannelIdentity.where(account: @account, channel: Corporate::Channels::SUPPORTED, verified_phone: [nil, '']).select(:contact_id)
    @account.contacts.where(phone_number: [nil, ''], id: identities).select(:id)
  end

  def incoming_contacts
    conversations = @account.messages.where(message_type: :incoming, sender_type: 'Contact').select(:conversation_id)
    @account.conversations.where(id: conversations).select(:contact_id)
  end

  def active_delivery_contacts
    deliveries = CorporateDelivery.where(account: @account, state: %w[pending in_flight unknown]).select(:message_id)
    conversations = @account.messages.where(id: deliveries).select(:conversation_id)
    @account.conversations.where(id: conversations).select(:contact_id)
  end
end
