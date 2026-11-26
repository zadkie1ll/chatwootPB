class CorporateDelivery < ApplicationRecord
  belongs_to :account
  belongs_to :message
  belongs_to :actor, class_name: 'User'
  validates :state, inclusion: { in: %w[pending in_flight sent failed unknown cancelled] }
  validates :message_id, uniqueness: { scope: :revision }
  validates :action, inclusion: { in: %w[send edit] }

  def set_state!(value, external_id: nil, error_code: nil)
    update!(state: value, external_message_id: external_id || external_message_id, error_code: error_code)
    return update_edit_message(value, error_code) if action == 'edit'

    attributes = message.content_attributes.to_h.merge(corporate_delivery: value, corporate_operation_id: operation_id)
    status = if %w[failed cancelled].include?(value)
               :failed
             elsif message.read?
               :read
             else
               :sent
             end
    message.update!(content_attributes: attributes, status: status, source_id: external_id || message.source_id)
    Corporate::ReadReceipts.apply(message) if value == 'sent'
  end

  private

  def update_edit_message(value, error_code)
    attributes = message.content_attributes.to_h.merge(corporate_edit_status: value, corporate_edit_error: error_code)
    changes = { content_attributes: attributes }
    if value == 'sent'
      changes[:content] = requested_content unless newer_telegram_revision?
      attributes[:corporate_edited_at] = Time.current.iso8601
    end
    message.update!(changes)
  end

  def newer_telegram_revision?
    revision_time = message.content_attributes.to_h['corporate_revision'].presence
    revision_time && Time.iso8601(revision_time.split('@').first) > created_at
  rescue ArgumentError
    false
  end
end
