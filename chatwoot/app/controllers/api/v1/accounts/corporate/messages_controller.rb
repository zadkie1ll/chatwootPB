class Api::V1::Accounts::Corporate::MessagesController < Api::V1::Accounts::BaseController
  def update
    conversation = ::Corporate.conversations(Current.account, Current.user).find_by!(display_id: params[:conversation_id])
    message = conversation.messages.find(params[:id])
    operation = ::Corporate::EditMessage.new(account: Current.account, actor: Current.user).perform(message, params.fetch(:content))
    render json: { operation_id: operation.operation_id, state: operation.state }, status: :accepted
  rescue ::Corporate::DispatchInProgress
    render json: { error: I18n.t('corporate.dispatch_in_progress') }, status: :conflict
  end
end
