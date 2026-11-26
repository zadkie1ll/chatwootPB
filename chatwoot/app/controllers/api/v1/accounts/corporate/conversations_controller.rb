class Api::V1::Accounts::Corporate::ConversationsController < Api::V1::Accounts::BaseController
  def create
    raise ActionController::BadRequest unless ::Corporate::Channels::SUPPORTED.include?(params[:channel])

    phone = params.require(:phone).to_s
    conversation = ::Corporate::StartConversation.new(account: Current.account, actor: Current.user).perform(phone, channel: params[:channel])
    render json: { conversation_id: conversation.display_id }
  rescue ::Corporate::CrmClient::Error
    render json: { error: I18n.t('corporate.crm_employee_not_mapped') }, status: :unprocessable_entity
  rescue ::Corporate::ChannelUnavailable, KeyError, SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED
    render json: { error: I18n.t('corporate.channel_unavailable') }, status: :service_unavailable
  rescue ArgumentError, ActiveRecord::RecordNotFound
    render json: { error: I18n.t(params[:channel] == 'max' ? 'corporate.max_recipient_unavailable' : 'corporate.recipient_unavailable') },
           status: :unprocessable_entity
  end
end
