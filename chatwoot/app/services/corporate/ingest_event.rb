class Corporate::IngestEvent
  def initialize(account:, inbox:)
    @account = account
    @inbox = inbox
  end

  def perform(event, attachments)
    @lookup_needed = false
    event = event.with_indifferent_access
    Corporate::TelegramEvent.validate!(event)
    @account.with_lock { process(event, attachments) }
  end

  private

  def process(event, attachments)
    key = event_key(event)
    receipt = CorporateInboxReceipt.find_by(account: @account, event_key: key)
    return receipt.message if receipt
    return if tombstoned?(event, key)

    identity = identity_for(event)
    message = Corporate::IncomingMessage.new(account: @account, inbox: @inbox).perform(event, identity, attachments)
    enqueue_lookup(message) if @lookup_needed && message && Corporate.crm_enabled?(@account)
    CorporateInboxReceipt.create!(account: @account, event_key: key, message: message)
    message
  end

  def event_key(event)
    fields = %i[external_account_id external_chat_id external_message_id event_type revision]
    Digest::SHA256.hexdigest(event.values_at(*fields).join('/'))
  end

  def tombstoned?(event, key)
    digest = Digest::SHA256.hexdigest(event.values_at(:external_account_id, :external_chat_id, :external_message_id).join('/'))
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
    identity = ChannelIdentity.find_by(account: @account, channel: 'telegram', external_account_id: event[:external_account_id],
                                       external_user_id: event[:external_user_id].to_s)
    return enrich_phone(identity, event) if identity

    contact = create_contact(event)
    @lookup_needed = event[:phone].present?
    ChannelIdentity.create!(account: @account, contact: contact, channel: 'telegram', external_account_id: event[:external_account_id],
                            external_user_id: event[:external_user_id].to_s, verified_phone: event[:phone])
  end

  def create_contact(event)
    contact = @account.contacts.create!(name: event[:sender_name].presence || I18n.t('corporate.unknown_contact'), phone_number: event[:phone],
                                        identifier: "telegram/#{event[:external_account_id]}/#{event[:external_user_id]}")
    shared = Corporate.shared_intake_enabled?(@account) && event[:direction] == 'incoming' && event[:phone].blank?
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
