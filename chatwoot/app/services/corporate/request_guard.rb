# Explicitly allow supported surfaces; new upstream endpoints remain closed.
class Corporate::RequestGuard
  CONTENT_ACTIONS = {
    'conversations' => %w[index show meta search filter update toggle_status toggle_priority toggle_typing_status update_last_seen unread attachments
                          mute unmute],
    'conversations/messages' => %w[index create],
    'conversations/labels' => %w[index],
    'conversations/participants' => %w[show],
    'conversations/draft_messages' => %w[show update destroy],
    'contacts' => %w[index active search filter show update contactable_inboxes],
    'contacts/conversations' => %w[index],
    'contacts/attachments' => %w[index],
    'contacts/notes' => %w[index show create update destroy],
    'contacts/labels' => %w[index],
    'search' => %w[index conversations contacts messages],
    'notifications' => %w[index update destroy read_all destroy_all unread_count snooze unread],
    'conversations/unread_counts' => %w[index],
    'corporate/summaries' => %w[create],
    'corporate/messages' => %w[update],
    'corporate/conversations' => %w[create],
    'corporate/ownerships' => %w[index update audit]
  }.freeze
  SHARED_READS = %w[agents assignable_agents teams canned_responses custom_attribute_definitions custom_filters].freeze

  DEDICATED_ACTIONS = {
    'corporate/max_channel' => { 'technical_admin' => %w[show connect] },
    'corporate/health' => { 'supervisor' => %w[show] },
    'corporate/channel' => { 'technical_admin' => %w[show connect] },
    'corporate/staff' => { 'supervisor' => %w[index create destroy] },
    'corporate/access' => { 'supervisor' => %w[show staff], 'manager' => %w[show], 'technical_admin' => %w[show] }
  }.freeze

  def initialize(controller)
    @controller = controller
    @account = Current.account
    @user = Current.user
    @role = Corporate.role(@account, @user)
    @resource = controller.controller_path.delete_prefix('api/v1/accounts/')
    @action = controller.action_name
    @params = controller.params
  end

  def check!
    deny! unless @role
    return check_crm! if @resource == 'corporate/crm'
    return if dedicated_action?
    return check_inbox! if @resource == 'inboxes'
    return if shared_action?

    check_content!
  end

  private

  def check_content!
    deny! if @role == 'technical_admin'
    deny! unless CONTENT_ACTIONS.fetch(@resource, []).include?(@action)
    deny! if @resource == 'corporate/ownerships' && @role != 'supervisor'
    check_contact!
    check_notification!
    check_contact_update!
  end

  def check_crm!
    return if @role == 'supervisor' && %w[employees update_employee].include?(@action)
    return if %w[manager supervisor].include?(@role) && %w[show bind reconcile].include?(@action)

    deny!
  end

  def dedicated_action?
    DEDICATED_ACTIONS.fetch(@resource, {}).fetch(@role, []).include?(@action)
  end

  def shared_action?
    return @action == 'index' if SHARED_READS.include?(@resource)

    @resource == 'notification_settings' && %w[show update].include?(@action)
  end

  def deny!
    raise ActiveRecord::RecordNotFound
  end

  def check_inbox!
    return if %w[index show assignable_agents].include?(@action)

    if @role == 'technical_admin' && @action == 'update'
      # Connector credentials have a dedicated flow. Generic webhook updates
      # would let a technical administrator route customer content elsewhere.
      deny! if @params.keys.excluding('controller', 'action', 'account_id', 'id', 'format', 'name').any?
      return
    end

    deny!
  end

  def check_contact!
    contact_id = if @resource.start_with?('contacts/')
                   @params[:contact_id]
                 elsif @resource == 'contacts' && %w[show update contactable_inboxes].include?(@action)
                   @params[:id]
                 end
    return if contact_id.blank?

    Corporate.contacts(@account, @user).find(contact_id)
  end

  def check_notification!
    return unless @resource == 'notifications' && @params[:id].present?

    notification = @user.notifications.where(account: @account).find(@params[:id])
    deny! unless notification.conversation && Corporate.can_read?(@account, @user, notification.conversation)
  end

  def check_contact_update!
    return unless @resource == 'contacts' && @action == 'update'

    # Identity changes and remote avatar fetching require dedicated audited flows.
    permitted = %w[name blocked]
    @params.keys.excluding('controller', 'action', 'account_id', 'id', 'format').each do |key|
      deny! unless permitted.include?(key)
    end
  end
end
