class Corporate::SharingService
  def initialize(account:, actor:)
    @account = account
    @actor = actor
  end

  def conversation(conversation, shared)
    validate_boolean!(shared)
    @account.with_lock do
      conversation = @account.conversations.find(conversation.id)
      raise ActiveRecord::RecordNotFound unless Corporate::SharingState.for(conversation, @actor)[:can_manage]
      raise ActiveRecord::RecordNotFound unless %w[manager supervisor].include?(Corporate.role(@account, @actor))

      share = conversation.corporate_conversation_share
      return if share.present? == shared

      shared ? conversation.create_corporate_conversation_share!(account: @account, shared_by: @actor) : share.destroy!
      conversation.association(:corporate_conversation_share).reset
      finish_change(@account.conversations.where(id: conversation.id), shared, shared ? 'conversation_shared' : 'conversation_private',
                    conversation: conversation)
    end
  end

  def absence(shared)
    validate_boolean!(shared)
    @account.with_lock do
      membership = Corporate.membership(@account, @actor)
      raise ActiveRecord::RecordNotFound unless membership&.role == 'manager'
      return if membership.chats_shared_while_absent? == shared

      membership.update!(chats_shared_while_absent: shared)
      Current.corporate_absence_cache = nil
      contacts = CustomerOwnership.where(account: @account, owner: @actor).select(:contact_id)
      finish_change(@account.conversations.where(contact_id: contacts), shared, shared ? 'absence_started' : 'absence_ended', subject_user: @actor)
    end
  end

  private

  def validate_boolean!(value)
    raise ActionController::BadRequest unless [true, false].include?(value)
  end

  def finish_change(scope, shared, action, **audit)
    fence_deliveries(scope) unless shared
    CorporateSharingAudit.create!(account: @account, actor: @actor, action: action, **audit)
    account_id = @account.id
    actor_id = @actor.id
    ActiveRecord.after_all_transactions_commit { Corporate::SharingChangedJob.perform_later(account_id, !shared, actor_id) }
  end

  def fence_deliveries(scope)
    messages = @account.messages.where(conversation_id: scope.select(:id)).select(:id)
    deliveries = CorporateDelivery.where(account: @account, message_id: messages, state: %w[pending in_flight unknown])
    deliveries.includes(:actor, message: :conversation).find_each do |delivery|
      next if Corporate.can_read?(@account, delivery.actor, delivery.message)

      raise Corporate::DispatchInProgress if %w[in_flight unknown].include?(delivery.state)

      delivery.set_state!('cancelled', error_code: 'sharing_closed')
    end
  end
end
