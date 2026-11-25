class Corporate::IncomingMessage
  include FileTypeHelper

  def initialize(account:, inbox:)
    @account = account
    @inbox = inbox
  end

  def perform(event, identity, attachments)
    @event = event
    @attachments = attachments
    conversation = conversation_for(identity)
    message = conversation.messages.find_by(source_id: event[:external_message_id].to_s)
    return delete_message(message) if event[:event_type] == 'deleted'
    return update_message(message) if message

    build_message(conversation, identity)
  end

  private

  def conversation_for(identity)
    contact_inbox = ContactInbox.find_or_create_by!(inbox: @inbox, source_id: identity.external_user_id) do |record|
      record.contact = identity.contact
    end
    contact_inbox.conversations.order(:id).last || Conversation.create!(account: @account, inbox: @inbox,
                                                                        contact: identity.contact, contact_inbox: contact_inbox)
  end

  def delete_message(message)
    message&.update!(content: I18n.t('conversations.messages.deleted'), content_attributes: { deleted: true })
    message&.attachments&.destroy_all
    message
  end

  def build_message(conversation, identity)
    message = conversation.messages.new(account: @account, inbox: @inbox, sender: identity.contact, message_type: @event[:direction],
                                        source_id: @event[:external_message_id].to_s, content: @event[:text].to_s,
                                        content_attributes: event_attributes.merge(corporate_origin: @event[:origin]))
    add_placeholder(message)
    attach_files(message)
    ensure_visible_error(message)
    message.save!
    message
  end

  def event_attributes
    { corporate_revision: @event[:event_type] == 'media' ? @event[:source_revision] : @event[:revision],
      corporate_media_state: @event[:attachment_state], corporate_media_error: @event[:attachment_error],
      corporate_media_id: @event[:media_id] }.compact.merge(corporate_media_error: @event[:attachment_error])
  end

  def add_placeholder(message)
    return if message.content.present?
    return unless @event[:attachment_state] == 'pending' || @event[:attachment_error].present?

    message.content = I18n.t(@event[:attachment_error].present? ? 'corporate.media_failed' : 'corporate.media_pending')
    message.content_attributes = message.content_attributes.to_h.merge(corporate_media_placeholder: true)
  end

  def update_message(message)
    return message unless %w[edited media].include?(@event[:event_type])
    return message if stale_revision?(message)

    apply_content(message)
    replace_media(message) if @event[:event_type] == 'media' && @attachments.present?
    ensure_visible_error(message)
    message.save!
    message
  end

  def stale_revision?(message)
    source = @event[:event_type] == 'media' ? @event[:source_revision].to_s : @event[:revision].to_s
    message.content_attributes.to_h['corporate_revision'].to_s > source
  end

  def apply_content(message)
    previous = message.content_attributes.to_h
    attributes = previous.merge(event_attributes.stringify_keys)
    if @event[:event_type] == 'edited' || previous['corporate_media_placeholder']
      message.content = @event[:text].to_s
      attributes.delete('corporate_media_placeholder')
    end
    message.content_attributes = attributes
  end

  def replace_media(message)
    return if message.content_attributes.to_h['corporate_attached_media_id'] == @event[:media_id] && message.attachments.exists?

    message.attachments.destroy_all
    attach_files(message)
  end

  def ensure_visible_error(message)
    return unless message.content.blank? && message.attachments.empty? && message.content_attributes.to_h['corporate_media_error'].present?

    message.content = I18n.t('corporate.media_failed')
  end

  def allowed_file?(file)
    return false unless Corporate::MessageSafety::ALLOWED_TYPES.include?(file.content_type)

    data = file.read
    file.rewind
    Corporate::FileTypes.allowed?(data, file.original_filename, file.content_type)
  end

  def attach_files(message)
    @attachments.each do |file|
      raise ArgumentError unless file.size.positive? && file.size <= Corporate::MessageSafety::MAX_BYTES

      unless allowed_file?(file)
        message.content_attributes = message.content_attributes.to_h.merge(corporate_media_error: 'unsupported_type', corporate_media_state: 'failed')
        next
      end
      metadata = { scan_state: 'clean' }
      metadata[:is_voice_message] = true if @event[:voice]
      message.content_attributes = message.content_attributes.to_h.merge(corporate_attached_media_id: @event[:media_id])
      message.attachments.build(account: @account, file: file, file_type: file_type(file.content_type), meta: metadata)
    end
  end
end
