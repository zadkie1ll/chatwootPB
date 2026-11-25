class Corporate::EditMessage
  def initialize(account:, actor:)
    @account = account
    @actor = actor
  end

  def perform(message, content)
    raise ActionController::BadRequest unless content.is_a?(String) && content.bytesize <= 100_000

    @account.with_lock do
      message.reload
      validate!(message, content)
      ownership = CustomerOwnership.find_by!(account: @account, contact_id: message.conversation.contact_id)
      revision = CorporateDelivery.where(message: message).maximum(:revision).to_i + 1
      delivery = CorporateDelivery.create!(account: @account, message: message, actor: @actor, action: 'edit', revision: revision,
                                           requested_content: content, assignment_version: ownership.lock_version)
      delivery.set_state!('pending')
      delivery
    end
  end

  private

  def validate!(message, content)
    raise ActiveRecord::RecordNotFound unless Corporate.can_read?(@account, @actor, message)
    raise ActionController::BadRequest unless editable?(message)

    raise ActionController::BadRequest if content.blank? && message.attachments.empty?
    raise Corporate::DispatchInProgress if CorporateDelivery.exists?(message: message, state: %w[pending in_flight unknown])
  end

  def editable?(message)
    message.outgoing? && !message.private? && message.source_id.present? && !message.content_attributes.to_h['deleted']
  end
end
