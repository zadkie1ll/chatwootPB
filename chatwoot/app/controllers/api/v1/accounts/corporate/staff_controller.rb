class Api::V1::Accounts::Corporate::StaffController < Api::V1::Accounts::BaseController
  rescue_from ActiveRecord::RecordInvalid, ArgumentError, with: lambda {
    render json: { error: I18n.t('corporate.invalid_staff') }, status: :unprocessable_entity
  }
  rescue_from ::Corporate::DispatchInProgress, with: -> { render json: { error: I18n.t('corporate.dispatch_in_progress') }, status: :conflict }

  def index
    memberships = CorporateMembership.where(account: Current.account, role: 'manager').includes(:user).order(:id).limit(200)
    render json: memberships.map { |member| { id: member.user_id, name: member.user.name, email: member.user.email, active: member.active } }
  end

  def create
    user = service.create(params.permit(:name, :email, :password).to_h.symbolize_keys)
    render json: user.as_json(only: [:id, :name, :email]), status: :created
  end

  def destroy
    service.disable(params[:id])
    head :no_content
  end

  private

  def service
    ::Corporate::StaffService.new(account: Current.account, actor: Current.user)
  end
end
