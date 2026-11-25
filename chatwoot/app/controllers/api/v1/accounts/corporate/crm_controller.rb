class Api::V1::Accounts::Corporate::CrmController < Api::V1::Accounts::BaseController
  before_action -> { raise ActiveRecord::RecordNotFound unless ::Corporate.crm_enabled?(Current.account) }
  rescue_from ::Corporate::CrmClient::Error, with: :crm_error
  rescue_from ::Corporate::DispatchInProgress, with: -> { render json: { error: I18n.t('corporate.dispatch_in_progress') }, status: :conflict }

  def employees
    directory = ::Corporate::CrmClient.new.call('employees')
    members = CorporateMembership.where(account: Current.account, role: 'manager', active: true).includes(:user).order(:id).limit(200)
    mappings = CorporateCrmEmployee.where(account: Current.account).pluck(:user_id, :external_user_id).to_h
    render json: { portal: directory.fetch('portal'), employees: directory.fetch('employees'),
                   managers: members.map do |member|
                     { id: member.user_id, name: member.user.name, email: member.user.email,
                       bitrix_user_id: mappings[member.user_id] }
                   end }
  end

  def update_employee
    user = Current.account.users.find(params[:id])
    raise ActiveRecord::RecordNotFound unless ::Corporate.role(Current.account, user) == 'manager'

    external_id = params.require(:bitrix_user_id).to_s
    raise ActionController::BadRequest unless external_id.match?(/\A[1-9]\d{0,17}\z/)

    directory = ::Corporate::CrmClient.new.call('employees')
    raise ActionController::BadRequest unless directory.fetch('employees').any? { |employee| employee.fetch('id') == external_id }

    save_mapping(user, external_id)
    head :no_content
  rescue ActiveRecord::RecordInvalid
    render json: { error: I18n.t('corporate.crm_mapping_conflict') }, status: :unprocessable_entity
  end

  def show
    render_link(scoped_conversation)
  end

  def bind
    conversation = scoped_conversation
    ::Corporate::CrmLinkService.new(account: Current.account, actor: Current.user).bind(
      conversation: conversation, phone: params[:phone].to_s, deal_url: params[:deal_url].to_s, owner_id: params[:owner_id]
    )
    render_link(conversation)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    render json: { error: I18n.t('corporate.crm_binding_conflict') }, status: :conflict
  end

  def reconcile
    conversation = scoped_conversation
    link = CorporateCrmLink.find_by!(account: Current.account, contact_id: conversation.contact_id)
    raise ActionController::BadRequest if link.external_deal_id.blank?

    ::Corporate::CrmSyncJob.perform_later(Current.account.id, link.id, link.operation_id)
    render_link(conversation)
  end

  private

  def save_mapping(user, external_id)
    Current.account.with_lock do
      mapping = CorporateCrmEmployee.find_or_initialize_by(account: Current.account, user: user)
      validate_mapping_change!(mapping, user, external_id)
      mapping.update!(external_user_id: external_id)
    end
  end

  def validate_mapping_change!(mapping, user, external_id)
    return unless mapping.persisted? && mapping.external_user_id != external_id

    owned = CustomerOwnership.where(account: Current.account, owner: user).select(:contact_id)
    raise ::Corporate::CrmClient::Error, 'crm_mapping_in_use' if CorporateCrmLink.exists?(account: Current.account, contact_id: owned)
  end

  def scoped_conversation
    ::Corporate.conversations(Current.account, Current.user).find_by!(display_id: params[:id])
  end

  def render_link(conversation)
    ownership = CustomerOwnership.find_by!(account: Current.account, contact_id: conversation.contact_id)
    link = CorporateCrmLink.find_by(account: Current.account, contact_id: conversation.contact_id)
    shared = ::Corporate.shared_intake_enabled?(Current.account) && ownership.shared_unidentified?
    render json: { enabled: ::Corporate.crm_enabled?(Current.account), shared: shared,
                   phone: conversation.contact.phone_number, state: link&.sync_state || 'unlinked', error_code: link&.error_code,
                   entity_type: link&.entity_type, deal_id: link&.external_deal_id, deal_title: link&.deal_title, deal_url: link&.deal_url,
                   employee_mapped: CorporateCrmEmployee.exists?(account: Current.account, user: Current.user) }
  end

  def crm_error(error)
    key = error.code.to_s.match?(/\A[a-z_]{1,60}\z/) ? error.code : 'crm_unavailable'
    render json: { error: I18n.t("corporate.#{key}", default: I18n.t('corporate.crm_unavailable')), error_code: key }, status: :unprocessable_entity
  end
end
