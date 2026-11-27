class Corporate::StaffDirectory
  PAGE_SIZE = 25
  STATUSES = %w[all active disabled].freeze

  def initialize(account, params)
    @account = account
    query = params.fetch(:q, '')
    raise ActionController::BadRequest unless query.is_a?(String)

    @query = query.strip
    @status = params.fetch(:status, 'all')
    @page = Integer(params.fetch(:page, 1), exception: false)
    raise ActionController::BadRequest unless STATUSES.include?(@status) && @page&.between?(1, 100_000) && @query.length <= 100
  end

  def perform
    members = filtered
    page = members.includes(:user).order(:user_id).offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE).to_a
    ids = page.map(&:user_id)
    counts = ownership_counts(ids)
    mappings = CorporateCrmEmployee.where(account: @account, user_id: ids).pluck(:user_id, :external_user_id).to_h
    devices = push_devices(ids)
    { api_version: 1, account_id: @account.id, payload: page.map { |member| row(member, counts, mappings, devices) },
      meta: { page: @page, per_page: PAGE_SIZE, total: members.count, summary: summary } }
  end

  private

  def members
    CorporateMembership.where(account: @account, role: 'manager')
  end

  def filtered
    scope = members
    scope = scope.where(active: @status == 'active') unless @status == 'all'
    return scope if @query.blank?

    user = User.arel_table
    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
    matching = @account.users.where(user[:name].matches(pattern).or(user[:email].matches(pattern)))
    scope.where(user_id: matching.select(:id))
  end

  def ownership_counts(ids)
    owned = CustomerOwnership.where(account: @account, owner_id: ids)
    contacts = owned.group(:owner_id).count
    conversations = @account.conversations.joins(contact: :customer_ownership)
                            .where(customer_ownerships: { account_id: @account.id,
                                                          owner_id: ids }).group(CustomerOwnership.arel_table[:owner_id]).count
    { contacts: contacts, conversations: conversations }
  end

  def push_devices(ids)
    Corporate::BrowserPush.subscriptions(@account).where(user_id: ids).group_by(&:user_id).transform_values do |subscriptions|
      live = subscriptions.select { |subscription| Corporate::BrowserPush.session_active?(subscription) }
      verified = live.count do |subscription|
        attrs = subscription.subscription_attributes
        attrs['confirmed_at'].present? && attrs['last_error'].blank?
      end
      { connected: live.size, verified: verified }
    end
  end

  def summary
    statuses = members.group(:active).count
    { total: statuses.values.sum, active: statuses.fetch(true, 0), disabled: statuses.fetch(false, 0),
      mapped: CorporateCrmEmployee.where(account: @account, user_id: members.select(:user_id)).count }
  end

  def row(member, counts, mappings, devices)
    user = member.user
    { id: user.id, account_id: @account.id, name: user.name, email: user.email, active: member.active,
      last_sign_in_at: user.current_sign_in_at || user.last_sign_in_at, created_at: user.created_at,
      absence: member.chats_shared_while_absent?, bitrix_user_id: mappings[user.id],
      clients_count: counts[:contacts].fetch(user.id, 0), conversations_count: counts[:conversations].fetch(user.id, 0),
      notifications: devices.fetch(user.id, { connected: 0, verified: 0 }) }
  end
end
