# Staff identity is local. Bitrix is an optional external mapping, not a login provider.
class Corporate::StaffCrm
  def initialize(account)
    @account = account
  end

  def employee(external_id)
    raise ActionController::BadRequest unless external_id.is_a?(String) && external_id.match?(/\A[1-9]\d{0,17}\z/)
    raise Corporate::CrmClient::Error, 'crm_not_configured' unless Corporate.crm_enabled?(@account)

    directory = Corporate::CrmClient.new.call('employees').fetch('employees')
    directory.find { |employee| employee.fetch('id') == external_id } || raise(ActionController::BadRequest)
  end

  def map!(user, external_id)
    mapping = CorporateCrmEmployee.find_or_initialize_by(account: @account, user: user)
    if mapping.persisted? && mapping.external_user_id != external_id
      owned = CustomerOwnership.where(account: @account, owner: user).select(:contact_id)
      raise Corporate::CrmClient::Error, 'crm_mapping_in_use' if CorporateCrmLink.exists?(account: @account, contact_id: owned)
    end
    mapping.update!(external_user_id: external_id)
  end
end
