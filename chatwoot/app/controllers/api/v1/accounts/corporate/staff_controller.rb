class Api::V1::Accounts::Corporate::StaffController < Api::V1::Accounts::BaseController
  rescue_from ActiveRecord::RecordInvalid, ArgumentError, with: lambda {
    render json: { error: I18n.t('corporate.invalid_staff') }, status: :unprocessable_entity
  }
  rescue_from ::Corporate::CrmClient::Error, with: :crm_error
  rescue_from ::Corporate::StaffService::CleanupPending, with: lambda {
    render json: { error: I18n.t('corporate.staff_cleanup_pending'), error_code: 'cleanup_pending' }, status: :conflict
  }
  rescue_from ::Corporate::DispatchInProgress, with: -> { render json: { error: I18n.t('corporate.dispatch_in_progress') }, status: :conflict }

  def index
    memberships = CorporateMembership.where(account: Current.account, role: 'manager').includes(:user).order(:id).limit(200)
    render json: memberships.map { |member| { id: member.user_id, name: member.user.name, email: member.user.email, active: member.active } }
  end

  def directory
    render json: ::Corporate::StaffDirectory.new(Current.account, params).perform
  end

  def create
    user = service.create(params.permit(:name, :email, :password, :bitrix_user_id).to_h.symbolize_keys)
    render json: user.as_json(only: [:id, :name, :email]), status: :created
  end

  def update
    user = service.update(params[:id], params.permit(:name, :email, :password, :bitrix_user_id).to_h.symbolize_keys)
    render json: user.as_json(only: [:id, :name, :email])
  end

  def enable
    service.enable(params[:id])
    head :no_content
  end

  def destroy
    service.disable(params[:id])
    head :no_content
  end

  private

  def crm_error(error)
    code = error.code.to_s.match?(/\A[a-z_]{1,60}\z/) ? error.code : 'crm_unavailable'
    render json: { error: I18n.t("corporate.#{code}", default: I18n.t('corporate.crm_unavailable')), error_code: code }, status: :unprocessable_entity
  end

  def service
    ::Corporate::StaffService.new(account: Current.account, actor: Current.user)
  end
end
