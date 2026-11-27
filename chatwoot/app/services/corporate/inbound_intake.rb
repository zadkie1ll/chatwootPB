# Unowned conversations may start in the official client before an inbound reply.
class Corporate::InboundIntake
  def initialize(account)
    @account = account
  end

  def received(identity, event)
    return false unless received_message?(event)
    return false if event[:sharing_restricted] == true
    return false unless eligible?(identity.contact)

    phone = identity.verified_phone.presence || identity.contact.phone_number
    return true if lookup_available?(phone, identity.channel)

    share(identity.contact)
    false
  end

  def share(contact)
    return false unless Corporate.shared_intake_enabled?(@account)

    @account.with_lock do
      return false unless eligible?(contact)
      return false unless @account.messages.incoming.exists?(conversation_id: @account.conversations.where(contact: contact).select(:id))

      ownership = CustomerOwnership.find_by!(account: @account, contact: contact)
      return false if ownership.shared_unidentified?

      ownership.update!(shared_unidentified: true)
      account_id = @account.id
      ActiveRecord.after_all_transactions_commit { Corporate::SharingChangedJob.perform_later(account_id, false) }
      true
    end
  end

  private

  def received_message?(event)
    event[:direction] == 'incoming' && event[:event_type] == 'received'
  end

  def lookup_available?(phone, channel)
    phone.present? && Corporate.crm_enabled?(@account) && Corporate::Channels.crm_enabled?(channel)
  end

  def eligible?(contact)
    return false if contact.additional_attributes.to_h['corporate_sharing_restricted'] == true

    ownership = CustomerOwnership.find_by(account: @account, contact: contact)
    return false unless ownership && ownership.owner_id.nil?
    return false if CorporateCrmLink.where(account: @account, contact: contact).where.not(external_deal_id: nil).exists?

    !AssignmentAudit.where(account: @account, contact: contact).where.not(new_owner_id: nil).exists?
  end
end
