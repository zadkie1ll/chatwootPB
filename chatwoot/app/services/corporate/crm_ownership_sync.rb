class Corporate::CrmOwnershipSync
  def initialize(account)
    @account = account
    raise ActiveRecord::RecordNotFound unless Corporate.crm_enabled?(account)
  end

  def links(after)
    rows = CorporateCrmLink.where(account: @account, sync_state: 'applied')
                           .where(CorporateCrmLink.arel_table[:id].gt(after)).order(:id).limit(20).to_a
    owners = CustomerOwnership.where(account: @account, contact_id: rows.map(&:contact_id)).index_by(&:contact_id)
    mappings = CorporateCrmEmployee.where(account: @account, user_id: owners.values.map(&:owner_id)).pluck(:user_id, :external_user_id).to_h
    rows.map { |link| link_data(link, owners.fetch(link.contact_id), mappings) }
  end

  def change_owner(params)
    @account.with_lock do
      link = CorporateCrmLink.find_by!(account: @account, id: params[:id])
      ownership = CustomerOwnership.find_by!(account: @account, contact_id: link.contact_id)
      return false unless current?(link, ownership, params)

      assign(link, params.require(:external_user_id), 'crm_responsible_changed')
      true
    end
  end

  def promote(params)
    @account.with_lock do
      link = CorporateCrmLink.find_by!(account: @account, id: params[:id], entity_type: 'lead')
      ownership = CustomerOwnership.find_by!(account: @account, contact_id: link.contact_id)
      return false unless current?(link, ownership, params)

      promote_link(link, params)
    end
  end

  private

  def link_data(link, ownership, mappings)
    { id: link.id, entity_type: link.entity_type, deal_id: link.external_deal_id, operation_id: link.operation_id,
      assignment_version: ownership.lock_version, owner_external_user_id: mappings[ownership.owner_id] }
  end

  def current?(link, ownership, params)
    link.sync_state == 'applied' && link.operation_id == params[:operation_id] && ownership.lock_version.to_s == params[:assignment_version].to_s
  end

  def mapped_owner(external_id)
    raise ActionController::BadRequest unless external_id.to_s.match?(/\A[1-9]\d{0,17}\z/)

    mapping = CorporateCrmEmployee.find_by(account: @account, external_user_id: external_id.to_s)
    return unless mapping && Corporate.role(@account, mapping.user) == 'manager'

    mapping.user_id
  end

  def assign(link, external_id, reason)
    Corporate::OwnershipService.new(account: @account, actor: nil).sync_from_crm(contact: link.contact,
                                                                                 owner_id: mapped_owner(external_id), reason: reason)
  end

  def promote_link(link, params)
    deal_id = params.require(:deal_id).to_s
    raise ActionController::BadRequest unless deal_id.match?(/\A[1-9]\d{0,17}\z/)

    conflicts = CorporateCrmLink.where(account: @account, entity_type: 'deal', external_deal_id: deal_id).where.not(id: link.id)
    return false if conflicts.exists?

    ownership = assign(link, params.require(:assigned_user_id), 'crm_lead_converted')
    url = link.deal_url.sub(%r{/crm/lead/details/\d+/?\z}, "/crm/deal/details/#{deal_id}/")
    link.update!(entity_type: 'deal', external_deal_id: deal_id, deal_title: params[:title].to_s.first(250), deal_url: url)
    Corporate::CrmLinkService.queue!(link, ownership: ownership, actor: link.actor, assign_owner: false)
    true
  end
end
