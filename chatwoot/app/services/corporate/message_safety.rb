class Corporate::MessageSafety
  MAX_BYTES = 20.megabytes
  ALLOWED_TYPES = %w[
    text/plain application/pdf application/zip application/octet-stream
    image/jpeg image/png image/gif image/webp
    audio/mpeg audio/ogg audio/mp4 audio/webm video/mp4 video/webm
    application/msword application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  ].freeze

  def self.validate!(user, conversation, params)
    raise ActiveRecord::RecordNotFound unless Corporate.can_read?(conversation.account, user, conversation)
    raise ActionController::BadRequest unless (params[:message_type].presence || 'outgoing') == 'outgoing'
    raise ActionController::BadRequest if params[:source_id].present? || params[:sender_type].present? || params[:sender_id].present?

    attributes = params[:content_attributes]
    attributes = JSON.parse(attributes) if attributes.is_a?(String)
    attributes = attributes.to_h.with_indifferent_access if attributes.respond_to?(:to_h)
    if attributes.present?
      raise ActionController::BadRequest unless (attributes.keys.map(&:to_s) - %w[in_reply_to]).empty?

      conversation.messages.find(attributes[:in_reply_to]) if attributes[:in_reply_to].present?
    end
    files = Array(params[:attachments])
    raise ActionController::BadRequest if files.length > 10
    raise ActionController::BadRequest if files.sum { |file| validate_file!(user, conversation, file) } > MAX_BYTES
  end

  def self.validate_file!(user, conversation, file)
    if file.is_a?(String)
      blob = ActiveStorage::Blob.find_signed!(file)
      authorised = blob.attachments.where(record_type: 'Attachment').any? do |attachment|
        Corporate.can_read?(conversation.account, user, attachment.record.message)
      end
      metadata = blob.metadata
      uploaded_here = metadata['corporate_account_id'] == conversation.account_id &&
                      metadata['corporate_contact_id'] == conversation.contact_id && metadata['corporate_user_id'] == user.id
      raise ActiveRecord::RecordNotFound unless authorised || uploaded_here

      size = blob.byte_size
      type = blob.content_type
    else
      size = file.size
      type = file.content_type
    end
    raise ActionController::BadRequest unless size.positive? && size <= MAX_BYTES && ALLOWED_TYPES.include?(type)

    size
  end
end
