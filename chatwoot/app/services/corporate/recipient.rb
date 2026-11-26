class Corporate::Recipient
  USERNAME = %r{\A(?:@|(?:https?://)?(?:t\.me|telegram\.me)/)?([a-zA-Z][a-zA-Z0-9_]{0,31})/?\z}

  def self.normalize(value, channel:)
    value = value.to_s.strip
    phone = normalize_phone(value)
    return phone if phone

    match = USERNAME.match(value) if channel == 'telegram'
    return "@#{match[1]}" if match

    raise ArgumentError, 'invalid_recipient'
  end

  def self.normalize_phone(value)
    return unless phone_text?(value)

    digits = value.gsub(/\D/, '')
    digits = "7#{digits}" if digits.length == 10 && !value.start_with?('+')
    digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
    "+#{digits}" if digits.match?(/\A7\d{10}\z/)
  end

  def self.phone_text?(value)
    value.match?(/\A\+?[\d\s().-]+\z/) && !value.match?(/\A\+[^78]/)
  end
end
