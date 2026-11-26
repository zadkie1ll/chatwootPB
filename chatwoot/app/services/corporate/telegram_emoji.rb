class Corporate::TelegramEmoji
  MAX_ENTITIES = 100

  def self.entities(event)
    return [] unless event[:channel] == 'telegram'

    text_length = event[:text].to_s.encode('UTF-16LE').bytesize / 2
    Array(event[:custom_emojis]).first(MAX_ENTITIES).filter_map do |item|
      next unless valid_entity?(item, text_length)

      item.slice(:offset, :length, :document_id)
    end
  end

  def self.valid_entity?(item, text_length)
    return false unless item.is_a?(Hash) && item[:document_id].to_s.match?(/\A\d{1,30}\z/)
    return false unless item[:offset].is_a?(Integer) && item[:length].is_a?(Integer)

    item[:offset] >= 0 && item[:length].positive? && item[:offset] + item[:length] <= text_length
  end

  def self.attachment_metadata(event, index)
    metadata = { scan_state: 'clean' }
    metadata[:is_voice_message] = true if event[:voice]
    emoji_id = Array(event[:attachments])[index]&.[](:emoji_document_id).to_s
    metadata[:telegram_custom_emoji_id] = emoji_id if entities(event).any? { |item| item[:document_id].to_s == emoji_id }
    metadata
  end
end
