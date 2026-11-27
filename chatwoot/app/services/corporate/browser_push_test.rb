class Corporate::BrowserPushTest
  PURPOSE = 'corporate_browser_push_test'.freeze
  EXPIRY = 5.minutes

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end

  def self.receive(token)
    data = verifier.verified(token, purpose: PURPOSE)
    return false unless data

    subscription = NotificationSubscription.find_by(id: data['subscription_id'], user_id: data['user_id'])
    return false unless subscription && Corporate::BrowserPush.session_active?(subscription)

    subscription.with_lock do
      attrs = subscription.subscription_attributes
      return false unless attrs['test_id'] == data['test_id']

      subscription.update!(subscription_attributes: attrs.merge('test_received_at' => Time.current.iso8601)) unless attrs['test_received_at']
    end
    true
  end

  def initialize(subscription)
    @subscription = subscription
  end

  def send!
    raise Corporate::BrowserPush::Error, 'not_configured' unless Corporate::BrowserPush.enabled?
    raise Corporate::BrowserPush::Error, 'session_required' unless Corporate::BrowserPush.session_active?(@subscription)

    test_id = prepare_test
    token = self.class.verifier.generate({ 'subscription_id' => @subscription.id, 'user_id' => @subscription.user_id, 'test_id' => test_id },
                                         purpose: PURPOSE, expires_in: EXPIRY)
    Corporate::BrowserPushSender.send!(@subscription, title: I18n.t('corporate.push.test_title'), body: I18n.t('corporate.push.test_body'),
                                                      tag: "corporate_test_#{test_id}", type: 'corporate_test', receipt_token: token,
                                                      url: "#{@subscription.subscription_attributes.fetch('origin')}/app")
  end

  def confirm!
    @subscription.with_lock do
      attrs = @subscription.subscription_attributes
      received = attrs['test_received_at']
      raise Corporate::BrowserPush::Error, 'test_not_received' unless received && Time.iso8601(received) > EXPIRY.ago

      @subscription.update!(subscription_attributes: attrs.merge('confirmed_at' => Time.current.iso8601))
    end
  end

  private

  def prepare_test
    test_id = SecureRandom.uuid
    @subscription.with_lock do
      attrs = @subscription.subscription_attributes
      if attrs['test_sent_at'].present? && Time.iso8601(attrs['test_sent_at']) > 10.seconds.ago
        raise Corporate::BrowserPush::Error,
              'test_rate_limited'
      end

      @subscription.update!(subscription_attributes: attrs.merge('test_id' => test_id, 'test_sent_at' => Time.current.iso8601,
                                                                 'test_received_at' => nil, 'confirmed_at' => nil))
    end
    test_id
  end
end
