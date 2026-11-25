class Api::V1::Accounts::Corporate::AccessController < Api::V1::Accounts::BaseController
  def staff
    raise Pundit::NotAuthorizedError unless ::Corporate.role(Current.account, Current.user) == 'supervisor'

    users = Current.account.users.where(id: CorporateMembership.where(account: Current.account, active: true, role: 'manager').select(:user_id))
    render json: users.as_json(only: [:id, :name])
  end

  def show
    role = ::Corporate.role(Current.account, Current.user)
    raise ActiveRecord::RecordNotFound unless role

    render json: { enabled: true, role: role, gateway_mode: ENV.fetch('TELEGRAM_MODE', 'personal'),
                   crm_enabled: ::Corporate.crm_enabled?(Current.account), shared_intake_enabled: ::Corporate.shared_intake_enabled?(Current.account) }
  end
end
