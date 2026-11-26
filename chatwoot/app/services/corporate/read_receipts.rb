class Corporate::ReadReceipts
  MAX_REMEMBERED_IDS = 1000

  def initialize(account:, inbox:)
    @account = account
    @inbox = inbox
  end

  def perform(event)
    identity = ChannelIdentity.find_by(account: @account, channel: event[:channel],
                                       external_account_id: event[:external_account_id], external_user_id: event[:external_user_id])
    return unless identity

    contact_inbox = ContactInbox.find_by(inbox: @inbox, contact: identity.contact, source_id: identity.external_user_id)
    contact_inbox&.conversations&.find_each { |conversation| apply_conversation(conversation, event) }
  end

  def apply_conversation(conversation, event)
    attributes = receipt_attributes(conversation, event)
    conversation.update!(additional_attributes: attributes)
    conversation.messages.outgoing.where(status: %w[sent delivered]).where.not(source_id: [nil, '']).find_each do |message|
      self.class.apply(message, attributes)
    end
  end

  def receipt_attributes(conversation, event)
    attributes = conversation.additional_attributes.to_h
    if event[:channel] == 'telegram'
      attributes['corporate_read_through'] = [attributes['corporate_read_through'].to_i, event[:external_message_id].to_i].max.to_s
    else
      ids = event[:read_message_ids] || [event[:external_message_id].to_s]
      attributes['corporate_read_ids'] = (Array(attributes['corporate_read_ids']) + ids).uniq.last(MAX_REMEMBERED_IDS)
    end
    attributes
  end

  def self.apply(message, attributes = message.conversation.reload.additional_attributes.to_h)
    return unless eligible?(message)

    message.update!(status: :read) if confirmed?(message.source_id, attributes)
  end

  def self.eligible?(message)
    message.outgoing? && !message.private? && message.source_id.to_s.match?(/\A\d+\z/) && !message.read? && !message.failed?
  end

  def self.confirmed?(source_id, attributes)
    return source_id.to_i <= attributes['corporate_read_through'].to_i if attributes['corporate_read_through'].present?

    Array(attributes['corporate_read_ids']).include?(source_id)
  end
end
