class Corporate::BrowserPushSender
  def self.send!(subscription, payload)
    attrs = subscription.subscription_attributes
    raise Corporate::BrowserPush::Error, 'invalid_subscription' unless Corporate::BrowserPush.valid_endpoint?(attrs['endpoint'])
    raise Corporate::BrowserPush::Error, 'origin_not_allowed' unless Corporate::BrowserPush.allowed_origins.include?(attrs['origin'])

    subject = ENV.fetch('CORPORATE_PUSH_SUBJECT') { "mailto:notifications@#{URI(ENV.fetch('FRONTEND_URL')).host}" }
    WebPush.payload_send(message: payload.to_json, endpoint: attrs.fetch('endpoint'), p256dh: attrs.fetch('p256dh'), auth: attrs.fetch('auth'),
                         vapid: { subject: subject, public_key: VapidService.public_key, private_key: VapidService.private_key },
                         ttl: 3600, ssl_timeout: 5, open_timeout: 5, read_timeout: 5)
    record_result(subscription, nil)
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
    subscription.destroy!
    raise Corporate::BrowserPush::Error, 'subscription_expired'
  rescue WebPush::ResponseError, IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
    record_result(subscription, 'push_unavailable')
    raise Corporate::BrowserPush::Error, 'push_unavailable'
  end

  def self.record_result(subscription, error)
    subscription.with_lock do
      subscription.update!(subscription_attributes: subscription.subscription_attributes.merge('last_error' => error))
    end
  rescue ActiveRecord::RecordNotFound
    # This browser was disconnected while the provider request was running.
    nil
  end
end
