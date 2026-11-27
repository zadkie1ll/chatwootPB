class Corporate::BrowserPush
  class Error < StandardError; end

  def self.enabled?
    Corporate.enabled? && ENV['CORPORATE_BROWSER_PUSH_ENABLED'] == 'true'
  end

  def self.allowed_origins
    ENV.fetch('CORPORATE_PUSH_ORIGINS', ENV.fetch('FRONTEND_URL', '')).split(',').map(&:strip)
  end

  def self.valid_endpoint?(endpoint)
    uri = URI.parse(endpoint.to_s)
    host_allowed = provider_host?(uri.host)
    uri.scheme == 'https' && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? && host_allowed && endpoint.length <= 4096
  rescue URI::InvalidURIError
    false
  end

  def self.provider_host?(host)
    %w[fcm.googleapis.com updates.push.services.mozilla.com web.push.apple.com].include?(host) ||
      host.to_s.match?(/\A[a-z0-9-]+\.notify\.windows\.com\z/)
  end

  def self.session_active?(subscription)
    attrs = subscription.subscription_attributes
    session = subscription.user.tokens.to_h[attrs['client']]
    session && session['expiry'].to_i > Time.current.to_i
  end

  def self.subscriptions(account)
    table = NotificationSubscription.arel_table
    account_key = Arel::Nodes::InfixOperation.new('->>', table[:subscription_attributes], Arel::Nodes.build_quoted('corporate_account_id'))
    NotificationSubscription.browser_push.where(account_key.eq(account.id.to_s)).includes(:user)
  end

  def initialize(account:, user:, origin:, client:)
    @account = account
    @user = user
    @origin = origin
    @client = client
    raise Error, 'origin_not_allowed' unless self.class.allowed_origins.include?(origin)
  end

  def find(endpoint)
    record = self.class.subscriptions(@account).where(user: @user).find_by(identifier: endpoint)
    return unless record && record.subscription_attributes['origin'] == @origin && record.subscription_attributes['client'] == @client

    record
  end

  def register(subscription)
    validate_registration!(subscription)

    attrs = registration_attributes(subscription)
    record = NotificationSubscription.find_or_initialize_by(identifier: subscription.fetch('endpoint'))
    record.with_lock do
      if record.user_id == @user.id && record.subscription_attributes.to_h['client'] == @client
        attrs = record.subscription_attributes.to_h.merge(attrs)
      end
      record.update!(user: @user, subscription_type: :browser_push, subscription_attributes: attrs)
    end
    record
  end

  def status(subscription)
    attrs = subscription&.subscription_attributes.to_h
    connected = subscription && attrs['origin'] == @origin && self.class.session_active?(subscription)
    values = connected ? attrs.slice('test_sent_at', 'test_received_at', 'confirmed_at', 'last_error') : {}
    { configured: self.class.enabled?, connected: connected.present? }.merge(values.symbolize_keys)
  end

  private

  def validate_registration!(subscription)
    raise Error, 'not_configured' unless self.class.enabled?
    raise Error, 'invalid_subscription' unless valid_subscription?(subscription)
    raise Error, 'session_required' unless @user.tokens.to_h.dig(@client, 'expiry').to_i > Time.current.to_i
  end

  def registration_attributes(subscription)
    subscription.fetch('keys').merge('endpoint' => subscription.fetch('endpoint'), 'origin' => @origin, 'client' => @client,
                                     'corporate_account_id' => @account.id.to_s)
  end

  def valid_subscription?(subscription)
    keys = subscription['keys'].to_h
    self.class.valid_endpoint?(subscription['endpoint']) && keys['p256dh'].to_s.match?(/\A[A-Za-z0-9_-]{87}=?\z/) &&
      keys['auth'].to_s.match?(/\A[A-Za-z0-9_-]{22}={0,2}\z/)
  end
end
