class Api::V1::Accounts::Corporate::SummariesController < Api::V1::Accounts::BaseController
  def create
    conversation = ::Corporate.conversations(Current.account, Current.user).find_by!(display_id: params[:conversation_id])
    return rate_limited unless claim_request_slot

    result = ::Corporate::ConversationSummary.new(conversation).call
    Current.account.with_lock do
      raise ActiveRecord::RecordNotFound unless ::Corporate.can_read?(Current.account, Current.user, conversation.reload)

      render json: result
    end
  rescue ::Corporate::ConversationSummary::Error => e
    render json: { error: I18n.t("corporate.summary.#{e.message}") }, status: :unprocessable_entity
  end

  private

  def claim_request_slot
    key = "corporate-summary:#{Current.account.id}:#{Current.user.id}"
    Rails.cache.write(key, true, expires_in: 45.seconds, unless_exist: true)
  end

  def rate_limited
    render json: { error: I18n.t('corporate.summary.busy') }, status: :too_many_requests
  end
end
