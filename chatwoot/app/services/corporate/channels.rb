class Corporate::Channels
  SUPPORTED = %w[telegram max].freeze

  def self.inbox_ids
    [ENV.fetch('CORPORATE_INBOX_ID'), ENV['CORPORATE_MAX_INBOX_ID'].presence].compact
  end

  def self.inbox(account, channel)
    raise ArgumentError unless SUPPORTED.include?(channel)

    key = channel == 'max' ? 'CORPORATE_MAX_INBOX_ID' : 'CORPORATE_INBOX_ID'
    inbox = account.inboxes.find(ENV.fetch(key))
    raise ArgumentError unless inbox.api?

    inbox
  end

  def self.for_conversation(conversation)
    configured = ENV['CORPORATE_MAX_INBOX_ID'].presence
    return conversation.inbox_id.to_s == configured ? 'max' : 'telegram' if configured

    conversation.additional_attributes['corporate_channel'].presence || 'telegram'
  end

  def self.crm_enabled?(channel)
    channel != 'max' || ENV['MAX_CRM_ENABLED'] == 'true'
  end

  def self.identity(conversation)
    ChannelIdentity.find_by!(account_id: conversation.account_id, contact_id: conversation.contact_id, channel: for_conversation(conversation))
  end
end
