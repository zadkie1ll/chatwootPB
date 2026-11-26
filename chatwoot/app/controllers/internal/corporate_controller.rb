class Internal::CorporateController < ActionController::Base # rubocop:disable Rails/ApplicationController -- Service token auth excludes browser session callbacks.
  skip_before_action :verify_authenticity_token
  before_action :authenticate_service
  before_action :set_scope
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  def crm_links
    render json: { links: Corporate::CrmOwnershipSync.new(@account).links(cursor) }
  end

  def crm_owner
    changed = Corporate::CrmOwnershipSync.new(@account).change_owner(params)
    head(changed ? :no_content : :conflict)
  rescue Corporate::DispatchInProgress
    head :conflict
  end

  def crm_target
    changed = Corporate::CrmOwnershipSync.new(@account).promote(params)
    head(changed ? :no_content : :conflict)
  rescue Corporate::DispatchInProgress
    head :conflict
  end

  def outbox
    expire_delivery_leases
    state = params.fetch(:state, 'pending').to_s
    raise ActionController::BadRequest unless %w[pending unknown in_flight].include?(state)

    records = deliveries.where(state: state).where(CorporateDelivery.arel_table[:id].gt(cursor)).order(:id).limit(50)
    render json: { operations: records.map { |delivery| operation_data(delivery) }, next_cursor: records.last&.id }
  end

  def claim
    @account.with_lock do
      delivery = deliveries.find_by!(operation_id: params[:id])
      return render json: { state: delivery.state }, status: :conflict unless delivery.state == 'pending'

      unless current_dispatch?(delivery)
        delivery.set_state!('cancelled', error_code: 'ownership_changed')
        return render json: { state: 'cancelled' }, status: :conflict
      end
      delivery.update!(dispatch_token: SecureRandom.hex(32), lease_expires_at: 60.seconds.from_now)
      delivery.set_state!('in_flight')
      render json: operation_data(delivery)
    end
  end

  def complete
    @account.with_lock do
      delivery = deliveries.find_by!(operation_id: params[:id])
      authenticate_dispatch!(delivery)
      external_id, error = completion_values
      return render json: { state: delivery.state } if delivery.state == 'sent'

      delivery.set_state!(params[:state], external_id: external_id, error_code: error)
      render json: { state: delivery.state }
    end
  end

  def attachment
    delivery = deliveries.find_by!(operation_id: params[:id])
    attachment = delivery.message.attachments.find(params[:attachment_id])
    return head :locked unless attachment.meta.to_h['scan_state'] == 'clean'

    response.headers['Cache-Control'] = 'no-store'
    stream_attachment(attachment)
  end

  def ingest
    event = params[:event].is_a?(String) ? JSON.parse(params[:event]) : params.require(:event).to_unsafe_h
    inbox = Corporate::Channels.inbox(@account, event.fetch('channel'))
    result = Corporate::IngestEvent.new(account: @account, inbox: inbox).perform(event, Array(params[:attachments]))
    render json: { message_id: result&.id }
  rescue JSON::ParserError, KeyError, ArgumentError
    render json: { error: 'invalid_event' }, status: :unprocessable_entity
  end

  private

  def stream_attachment(attachment)
    attachment.file.blob.open { |file| send_data file.read, filename: attachment.file.filename.to_s, type: attachment.file.content_type }
  end

  def cursor
    value = params.fetch(:after, '0').to_s
    raise ActionController::BadRequest unless value.match?(/\A\d{1,18}\z/)

    value.to_i
  end

  def expire_delivery_leases
    @account.with_lock do
      deliveries.where(state: 'in_flight').where(lease_expires_at: ...Time.current).find_each do |delivery|
        delivery.set_state!('unknown', error_code: 'lease_expired')
      end
    end
  end

  def current_dispatch?(delivery)
    ownership = CustomerOwnership.find_by!(account: @account, contact_id: delivery.message.conversation.contact_id)
    ownership.lock_version == delivery.assignment_version && Corporate.can_read?(@account, delivery.actor, delivery.message)
  end

  def authenticate_dispatch!(delivery)
    supplied = params[:dispatch_token].to_s
    return if delivery.dispatch_token.present? && ActiveSupport::SecurityUtils.secure_compare(delivery.dispatch_token, supplied)

    raise ActiveRecord::RecordNotFound
  end

  def completion_values
    raise ActionController::BadRequest unless %w[sent failed unknown pending].include?(params[:state])
    raise ActionController::BadRequest if params[:state] == 'pending' && params[:error_code] != 'flood_wait'

    external_id = completion_external_id
    error = params[:error_code].presence.to_s
    error = 'external_failure' unless error.match?(/\A[a-z_]{0,60}\z/)
    [external_id, error.presence]
  end

  def completion_external_id
    external_id = params[:external_message_id].presence&.to_s
    raise ActionController::BadRequest if params[:state] == 'sent' && !external_id&.match?(/\A\d{1,30}\z/)

    external_id
  end

  def authenticate_service
    expected = ENV['CW_SERVICE_TOKEN'].to_s
    supplied = request.authorization.to_s.delete_prefix('Bearer ')
    head :not_found unless expected.length >= 32 && ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
  end

  def set_scope
    @account = Account.find(ENV.fetch('CORPORATE_ACCOUNT_ID'))
    @inbox = @account.inboxes.find(ENV.fetch('CORPORATE_INBOX_ID'))
    raise ActiveRecord::RecordNotFound unless @inbox.api?
  end

  def deliveries
    CorporateDelivery.where(account: @account, message_id: @account.messages.where(inbox_id: Corporate::Channels.inbox_ids).select(:id))
  end

  def operation_data(delivery)
    message = delivery.message
    identity = Corporate::Channels.identity(message.conversation)
    {
      channel: identity.channel, action: delivery.action, target_message_id: delivery.action == 'edit' ? message.source_id : nil,
      operation_id: delivery.operation_id, state: delivery.state, dispatch_token: delivery.dispatch_token,
      assignment_version: delivery.assignment_version, message_id: message.id,
      external_account_id: identity.external_account_id, external_user_id: identity.external_user_id,
      text: delivery.action == 'edit' ? delivery.requested_content : message.content.to_s,
      reply_to: message.content_attributes['in_reply_to_external_id'], attachments: delivery_attachments(delivery)
    }
  end

  def delivery_attachments(delivery)
    return [] if delivery.action == 'edit'

    delivery.message.attachments.map do |attachment|
      { id: attachment.id, filename: attachment.file.filename.to_s, size: attachment.file.byte_size,
        content_type: attachment.file.content_type, voice: attachment.meta&.fetch('is_voice_message', false) }
    end
  end
end
