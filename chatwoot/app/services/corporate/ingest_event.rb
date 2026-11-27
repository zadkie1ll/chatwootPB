class Corporate::IngestEvent
  def initialize(account:, inbox:)
    @account = account
    @inbox = inbox
  end

  def perform(event, attachments)
    @lookup_needed = false
    event = event.with_indifferent_access
    Corporate::TelegramEvent.validate!(event)
    @account.with_lock do
      event[:event_type] == 'read' ? ingest_read(event) : process(event, attachments)
    end
  end

  private

  def ingest_read(event)
    key = event_key(event)
    return if CorporateInboxReceipt.exists?(account: @account, event_key: key)

    Corporate::ReadReceipts.new(account: @account, inbox: @inbox).perform(event)
    CorporateInboxReceipt.create!(account: @account, event_key: key)
    nil
  end

  def process(event, attachments)
    key = event_key(event)
    receipt = CorporateInboxReceipt.find_by(account: @account, event_key: key)
    return receipt.message if receipt
    return if tombstoned?(event, key)

    identity = identity_for(event)
    message = Corporate::IncomingMessage.new(account: @account, inbox: @inbox).perform(event, identity, attachments)
    if message
      route_inbound(message, identity, event)
      Corporate::ChannelContact.refresh_crm(@account, message.conversation)
    end
    CorporateInboxReceipt.create!(account: @account, event_key: key, message: message)
    message
  end

  def route_inbound(message, identity, event)
    inbound_lookup = Corporate::InboundIntake.new(@account).received(identity, event)
    return unless @lookup_needed || inbound_lookup
    return unless Corporate.crm_enabled?(@account) && Corporate::Channels.crm_enabled?(event[:channel])

    enqueue_lookup(message)
  end

  def event_key(event)
    fields = %i[external_account_id external_chat_id external_message_id event_type revision]
    Digest::SHA256.hexdigest(scoped_values(event, fields))
  end

  def scoped_values(event, fields)
    values = event.values_at(*fields)
    values.unshift(event[:channel]) unless event[:channel] == 'telegram'
    values.join('/')
  end

  def tombstoned?(event, key)
    digest = Digest::SHA256.hexdigest(scoped_values(event, %i[external_account_id external_chat_id external_message_id]))
    tombstone = "tombstone/#{digest}"
    if event[:event_type] == 'deleted'
      CorporateInboxReceipt.find_or_create_by!(account: @account, event_key: tombstone)
    elsif CorporateInboxReceipt.exists?(account: @account, event_key: tombstone)
      CorporateInboxReceipt.create!(account: @account, event_key: key)
      return true
    end
    false
  end

  def identity_for(event)
    identity = ChannelIdentity.find_by(account: @account, channel: event[:channel], external_account_id: event[:external_account_id],
                                       external_user_id: event[:external_user_id].to_s)
    return enrich_phone(identity, event) if identity

    contact = create_contact(event)
    @lookup_needed = event[:phone].present?
    ChannelIdentity.create!(account: @account, contact: contact, channel: event[:channel], external_account_id: event[:external_account_id],
                            external_user_id: event[:external_user_id].to_s, verified_phone: event[:phone])
  end

  def create_contact(event)
    existing = Corporate::ChannelContact.find(@account, event[:phone])
    return existing if existing

    contact = @account.contacts.create!(name: event[:sender_name].presence || I18n.t('corporate.unknown_contact'), phone_number: event[:phone],
                                        identifier: "#{event[:channel]}/#{event[:external_account_id]}/#{event[:external_user_id]}",
                                        additional_attributes: { corporate_sharing_restricted: event[:sharing_restricted] == true })
    shared = Corporate.shared_intake_enabled?(@account) && event[:direction] == 'incoming' &&
             event[:phone].blank? && event[:sharing_restricted] != true
    CustomerOwnership.create!(account: @account, contact: contact, shared_unidentified: shared)
    contact
  end

  def enrich_phone(identity, event)
    return identity unless identity.verified_phone.blank? && event[:phone].present?

    identity.update!(verified_phone: event[:phone])
    identity.contact.update!(phone_number: event[:phone]) if identity.contact.phone_number.blank?
    @lookup_needed = true
    identity
  end

  def enqueue_lookup(message)
    account_id = @account.id
    conversation_id = message.conversation_id
    ActiveRecord.after_all_transactions_commit { Corporate::CrmInboundLookupJob.perform_later(account_id, conversation_id) }
  end
end
