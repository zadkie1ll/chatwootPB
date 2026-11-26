class Corporate::MessageSafety
  MAX_BYTES = 20.megabytes
  ALLOWED_TYPES = %w[
    application/vnd.apple.numbers application/vnd.apple.pages application/vnd.apple.keynote
    application/x-iwork-numbers-sffnumbers application/x-iwork-pages-sffpages application/x-iwork-keynote-sffkey
    text/plain application/pdf application/zip application/octet-stream
    image/jpeg image/png image/gif image/webp
    audio/mpeg audio/ogg audio/mp4 audio/webm video/mp4 video/webm
    application/msword application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  ].freeze

  def self.validate!(user, conversation, params)
    validate_sender!(user, conversation, params)
    validate_attributes!(conversation, params[:content_attributes])
    files = Array(params[:attachments])
    validate_max_file_count!(conversation, params, files)
    raise ActionController::BadRequest if files.length > 10
    raise ActionController::BadRequest if files.sum { |file| validate_file!(user, conversation, file) } > MAX_BYTES
  end

  def self.validate_sender!(user, conversation, params)
    raise ActiveRecord::RecordNotFound unless Corporate.can_read?(conversation.account, user, conversation)
    raise ActionController::BadRequest unless (params[:message_type].presence || 'outgoing') == 'outgoing'
    raise ActionController::BadRequest if params[:source_id].present? || params[:sender_type].present? || params[:sender_id].present?
  end

  def self.validate_attributes!(conversation, attributes)
    attributes = JSON.parse(attributes) if attributes.is_a?(String)
    attributes = attributes.to_h.with_indifferent_access if attributes.respond_to?(:to_h)
    return if attributes.blank?

    raise ActionController::BadRequest unless (attributes.keys.map(&:to_s) - %w[in_reply_to]).empty?

    conversation.messages.find(attributes[:in_reply_to]) if attributes[:in_reply_to].present?
  end

  def self.validate_max_file_count!(conversation, params, files)
    return if files.length <= 1 || ActiveModel::Type::Boolean.new.cast(params[:private])
    return unless Corporate::Channels.for_conversation(conversation) == 'max'

    conversation.errors.add(:base, I18n.t('corporate.max_file_count'))
    raise ActiveRecord::RecordInvalid, conversation
  end

  def self.validate_file!(user, conversation, file)
    if file.is_a?(String)
      blob = authorised_blob!(user, conversation, file)
      size = blob.byte_size
      type = blob.content_type
    else
      size = file.size
      type = file.content_type
    end
    raise ActionController::BadRequest unless size.positive? && size <= MAX_BYTES && ALLOWED_TYPES.include?(type)

    size
  end

  def self.authorised_blob!(user, conversation, token)
    blob = ActiveStorage::Blob.find_signed!(token)
    authorised = blob.attachments.where(record_type: 'Attachment').any? do |attachment|
      Corporate.can_read?(conversation.account, user, attachment.record.message)
    end
    raise ActiveRecord::RecordNotFound unless authorised || uploaded_here?(user, conversation, blob.metadata)

    blob
  end

  def self.uploaded_here?(user, conversation, metadata)
    metadata['corporate_account_id'] == conversation.account_id && metadata['corporate_contact_id'] == conversation.contact_id &&
      metadata['corporate_user_id'] == user.id
  end
end
