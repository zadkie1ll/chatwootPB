class Api::V1::Accounts::Corporate::OwnershipsController < Api::V1::Accounts::BaseController
  def index
    raise Pundit::NotAuthorizedError unless ::Corporate.role(Current.account, Current.user) == 'supervisor'

    scope = CustomerOwnership.where(account: Current.account)
    scope = scope.where(contact_id: Array(params[:contact_ids]).take(50)) if params[:contact_ids].present?
    @ownerships = scope.order(:contact_id).page(params[:page]).per(50)
    render json: @ownerships.as_json(only: [:contact_id, :owner_id, :assigned_at, :lock_version])
  end

  def update
    contact = Current.account.contacts.find(params[:id])
    owner_id = params[:owner_id].presence&.to_i
    reason = params.require(:reason).to_s
    raise ActionController::BadRequest unless reason.present? && reason.length <= 500

    ownership = ::Corporate::OwnershipService.new(account: Current.account, actor: Current.user).transfer(
      contact: contact, owner_id: owner_id, reason: reason
    )
    render json: ownership.as_json(only: [:contact_id, :owner_id, :assigned_at, :lock_version])
  rescue ::Corporate::DispatchInProgress
    render json: { error: I18n.t('corporate.dispatch_in_progress') }, status: :conflict
  rescue ::Corporate::CrmClient::Error
    render json: { error: I18n.t('corporate.crm_employee_not_mapped') }, status: :unprocessable_entity
  end

  def audit
    raise Pundit::NotAuthorizedError unless ::Corporate.role(Current.account, Current.user) == 'supervisor'

    records = AssignmentAudit.where(account: Current.account).order(id: :desc).page(params[:page]).per(50)
    render json: records.as_json(only: [:id, :contact_id, :actor_id, :old_owner_id, :new_owner_id, :reason, :correlation_id, :assignment_version,
                                        :created_at, :source])
  end
end
