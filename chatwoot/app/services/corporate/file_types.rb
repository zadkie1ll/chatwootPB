class Corporate::FileTypes
  def self.allowed?(data, filename, declared_type)
    detected = Marcel::MimeType.for(StringIO.new(data), name: filename.to_s, declared_type: declared_type)
    Corporate::MessageSafety::ALLOWED_TYPES.include?(detected)
  end
end
