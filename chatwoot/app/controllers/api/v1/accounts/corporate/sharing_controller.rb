class Api::V1::Accounts::Corporate::SharingController < Api::V1::Accounts::BaseController
  rescue_from ::Corporate::DispatchInProgress do
    render json: { error: I18n.t('corporate.dispatch_in_progress') }, status: :conflict
  end

  def show
    render json: { absence: ::Corporate.membership(Current.account, Current.user).chats_shared_while_absent? }
  end

  def conversation
    render json: ::Corporate::SharingState.for(shared_conversation, Current.user)
  end

  def update
    target = shared_conversation
    service.conversation(target, params.fetch(:shared))
    render json: ::Corporate::SharingState.for(target.reload, Current.user)
  end

  def absence
    service.absence(params.fetch(:shared))
    show
  end

  private

  def shared_conversation
    ::Corporate.conversations(Current.account, Current.user).find_by!(display_id: params[:id])
  end

  def service
    ::Corporate::SharingService.new(account: Current.account, actor: Current.user)
  end
end
