class Corporate::AttachmentScanJob < ApplicationJob
  queue_as :default
  retry_on Corporate::Antivirus::Unavailable, wait: 15.seconds, attempts: :unlimited

  def perform(attachment_id)
    return unless Corporate.enabled?

    attachment = Attachment.find_by(id: attachment_id)
    return unless scannable?(attachment)

    blob_id = attachment.file.blob.id
    clean = clean_file?(attachment)
    attachment.account.with_lock do
      attachment.reload
      return unless attachment.file.attached? && attachment.file.blob.id == blob_id

      attachment.update!(meta: attachment.meta.to_h.merge('scan_state' => clean ? 'clean' : 'rejected'))
      update_message(attachment.message)
    end
  end

  private

  def scannable?(attachment)
    return false unless attachment&.file&.attached?

    %w[clean rejected].exclude?(attachment.meta.to_h['scan_state'])
  end

  def clean_file?(attachment)
    return false if attachment.file.byte_size > Corporate::MessageSafety::MAX_BYTES

    attachment.file.blob.open do |file|
      data = file.read(Corporate::MessageSafety::MAX_BYTES + 1)
      return false if data.bytesize > Corporate::MessageSafety::MAX_BYTES
      return false unless Corporate::FileTypes.allowed?(data, attachment.file.filename, attachment.file.content_type)

      Corporate::Antivirus.scan(data)
    end
  end

  def update_message(message)
    states = message.attachments.map { |file| file.meta.to_h['scan_state'] }
    state = if states.include?('rejected')
              'rejected'
            else
              states.all?('clean') ? 'ready' : 'pending'
            end
    message.update!(content_attributes: message.content_attributes.to_h.merge(corporate_attachments_state: state))
    return unless state == 'rejected'

    delivery = CorporateDelivery.find_by(message: message, state: 'pending')
    delivery&.set_state!('failed', error_code: 'attachment_rejected')
  end
end
