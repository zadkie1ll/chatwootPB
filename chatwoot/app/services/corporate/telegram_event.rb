class Corporate::TelegramEvent
  def self.validate!(event)
    raise ArgumentError unless valid_identity?(event) && valid_message?(event) && valid_phone?(event)
  end

  def self.valid_identity?(event)
    Corporate::Channels::SUPPORTED.include?(event[:channel]) && event[:external_user_id].to_s.match?(/\A\d{1,30}\z/) &&
      valid_chat?(event) && event[:external_account_id].to_s.length.between?(1, 100)
  end

  def self.valid_chat?(event)
    return event[:external_chat_id].to_s == event[:external_user_id].to_s if event[:channel] == 'telegram'

    event[:external_account_id].to_s.match?(/\A\d{1,30}\z/) &&
      event[:external_chat_id].to_s == (event[:external_account_id].to_i ^ event[:external_user_id].to_i).to_s
  end

  def self.valid_message?(event)
    event[:external_message_id].to_s.match?(/\A\d{1,30}\z/) && %w[received edited deleted media].include?(event[:event_type]) &&
      %w[incoming outgoing].include?(event[:direction]) && event[:text].to_s.bytesize <= 100_000
  end

  def self.valid_phone?(event)
    event[:phone].blank? || event[:phone].to_s.match?(/\A\+[1-9]\d{6,14}\z/)
  end
end
