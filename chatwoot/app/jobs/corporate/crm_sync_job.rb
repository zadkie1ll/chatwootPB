class Corporate::CrmSyncJob < ApplicationJob
  queue_as :default

  def perform(account_id, link_id, operation_id, attempt = 0)
    return unless Corporate.crm_enabled?

    @account = Account.find(account_id)
    return unless Corporate.crm_enabled?(@account)

    @operation_id = operation_id
    @attempt = attempt
    payload = claim_payload(link_id)
    return unless payload

    result = Corporate::CrmClient.new.call('publish', payload)
    state = { 'applied' => 'applied', 'pending' => 'pending', 'failed' => 'error' }.fetch(result['state'], 'unknown')
    complete(state, result['error'])
  rescue Corporate::CrmClient::Error => e
    complete(e.definitive ? 'error' : 'unknown', e.code) if @link
  end

  private

  def claim_payload(link_id)
    @account.with_lock do
      @link = CorporateCrmLink.find_by(account: @account, id: link_id, operation_id: @operation_id)
      return if @link.nil? || @link.sync_state == 'applied'
      return if @link.sync_state == 'sending' && @link.lease_expires_at&.future?
      return unless assignment_current?

      @link.update!(sync_state: 'sending', lease_expires_at: 90.seconds.from_now)
      @link.sync_payload
    end
  end

  def assignment_current?
    ownership = CustomerOwnership.find_by!(account: @account, contact_id: @link.contact_id)
    if ownership.lock_version == @link.assignment_version && (ownership.owner_id.present? || @link.sync_payload['assigned_user_id'].blank?)
      return true
    end

    @link.update!(sync_state: 'error', error_code: 'ownership_changed')
    false
  end

  def complete(state, error)
    @account.with_lock do
      @link.reload
      return unless @link.operation_id == @operation_id

      @link.update!(sync_state: state, error_code: error.presence, lease_expires_at: nil)
    end
    return unless %w[pending unknown].include?(state) && @attempt < 20

    self.class.set(wait: 30.seconds).perform_later(@account.id, @link.id, @operation_id, @attempt + 1)
  end
end
