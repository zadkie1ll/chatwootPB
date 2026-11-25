class Corporate::CrmLinkService
  def initialize(account:, actor:)
    @account = account
    @actor = actor
    raise Corporate::CrmClient::Error, 'crm_not_configured' unless Corporate.crm_enabled?(account)
    raise Pundit::NotAuthorizedError unless %w[manager supervisor].include?(Corporate.role(account, actor))
  end

  def bind(conversation:, **options)
    raise ActiveRecord::RecordNotFound unless Corporate.can_read?(@account, @actor, conversation)

    result = Corporate::CrmClient.new.call('resolve', { phone: options.fetch(:phone, ''), deal_url: options.fetch(:deal_url, '') })
    @account.with_lock do
      conversation.reload
      raise ActiveRecord::RecordNotFound unless Corporate.can_read?(@account, @actor, conversation)

      link = CorporateCrmLink.find_or_initialize_by(account: @account, contact: conversation.contact)
      validate_binding!(link, options[:expected_version])
      return mark_not_found(link, conversation, result, options) unless result.fetch('found')

      bind_result(link, conversation, result, options)
    end
  end

  def self.queue!(link, ownership:, actor:, assign_owner: true)
    mapping = CorporateCrmEmployee.find_by(account_id: link.account_id, user_id: ownership.owner_id)
    raise Corporate::CrmClient::Error, 'crm_employee_not_mapped' unless mapping || !assign_owner

    operation_id = SecureRandom.uuid
    chat_url = "#{ENV.fetch('FRONTEND_URL').chomp('/')}/app/accounts/#{link.account_id}/conversations/#{link.conversation.display_id}"
    payload = { operation_id: operation_id, deal_id: link.external_deal_id, entity_type: link.entity_type, chat_url: chat_url }
    payload[:assigned_user_id] = mapping.external_user_id if assign_owner
    link.update!(operation_id: operation_id, actor: actor, sync_payload: payload, assignment_version: ownership.lock_version,
                 sync_state: 'pending', error_code: nil, lease_expires_at: nil)
    ActiveRecord.after_all_transactions_commit { Corporate::CrmSyncJob.perform_later(link.account_id, link.id, operation_id) }
  end

  private

  def validate_binding!(link, expected_version)
    ownership = CustomerOwnership.find_by!(account: @account, contact_id: link.contact_id)
    raise ActiveRecord::RecordNotFound if expected_version && (ownership.lock_version != expected_version || link.external_deal_id.present?)
    raise Corporate::DispatchInProgress if link.dispatch_unresolved?
  end

  def mark_not_found(link, conversation, result, options)
    raise Corporate::CrmClient::Error, 'crm_deal_not_found' if link.external_deal_id.present?

    link.update!(conversation: conversation, actor: @actor, operation_id: SecureRandom.uuid,
                 sync_state: 'not_found', phone: result['phone'], phone_source: options.fetch(:source, 'entered'), error_code: 'crm_deal_not_found')
    link
  end

  def bind_result(link, conversation, result, options)
    reject_existing_deal!(link, result)
    owner = choose_owner(result, options[:owner_id], conversation.contact)
    ownership = assign_owner(conversation.contact, owner)
    conversation.contact.update!(phone_number: result['phone']) if result['phone'].present?
    link.assign_attributes(conversation: conversation, actor: @actor, external_deal_id: result.fetch('deal_id'),
                           entity_type: result.fetch('entity_type', 'deal'),
                           deal_title: result.fetch('title'), deal_url: result.fetch('deal_url'),
                           phone: result['phone'], phone_source: options.fetch(:source, 'entered'))
    self.class.queue!(link, ownership: ownership, actor: @actor)
    link
  end

  def reject_existing_deal!(link, result)
    exists = CorporateCrmLink.where(account: @account, external_deal_id: result.fetch('deal_id'),
                                    entity_type: result.fetch('entity_type', 'deal')).where.not(contact_id: link.contact_id).exists?
    raise Corporate::CrmClient::Error, 'crm_deal_already_linked' if exists
  end

  def choose_owner(result, supplied_id, contact)
    return @actor if Corporate.role(@account, @actor) == 'manager'

    owner_id = supplied_id.presence || CustomerOwnership.find_by!(account: @account, contact: contact).owner_id
    owner_id ||= CorporateCrmEmployee.find_by(account: @account, external_user_id: result.fetch('assigned_user_id'))&.user_id
    raise Corporate::CrmClient::Error, 'crm_assignee_required' unless owner_id

    user = @account.users.find(owner_id)
    raise Corporate::CrmClient::Error, 'crm_assignee_required' unless Corporate.role(@account, user) == 'manager'

    user
  end

  def assign_owner(contact, owner)
    service = Corporate::OwnershipService.new(account: @account, actor: @actor)
    if Corporate.role(@account, @actor) == 'manager'
      service.claim(contact: contact, reason: 'crm_linked')
    else
      service.transfer(contact: contact, owner_id: owner.id, reason: 'crm_linked')
    end
  end
end
