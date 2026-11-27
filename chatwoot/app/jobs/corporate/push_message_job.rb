class Corporate::PushMessageJob < ApplicationJob
  queue_as :low
  retry_on Corporate::BrowserPush::Error, wait: :polynomially_longer, attempts: 3

  def perform(message_id)
    return unless Corporate::BrowserPush.enabled?

    message = Message.find_by(id: message_id)
    return unless eligible?(message)

    Current.corporate_read_cache = nil
    Current.corporate_absence_cache = nil
    failures = []
    Corporate::BrowserPush.subscriptions(message.account).find_each do |subscription|
      next unless Corporate::BrowserPush.session_active?(subscription)
      next unless Corporate.can_read?(message.account, subscription.user, message)

      begin
        I18n.with_locale(message.account.locale) { send_message(subscription, message) }
      rescue Corporate::BrowserPush::Error => e
        failures << e
      end
    end
    raise failures.first if failures.any?
  end

  private

  def eligible?(message)
    message&.incoming? && !message.private? && !message.conversation.contact.blocked?
  end

  def send_message(subscription, message)
    attrs = subscription.subscription_attributes
    url = "#{attrs.fetch('origin')}/app/accounts/#{message.account_id}/conversations/#{message.conversation.display_id}"
    Corporate::BrowserPushSender.send!(subscription, title: I18n.t('corporate.push.message_title'), body: I18n.t('corporate.push.message_body'),
                                                     tag: "corporate_chat_#{message.account_id}_#{message.conversation_id}", url: url)
  rescue Corporate::BrowserPush::Error => e
    raise unless e.message == 'subscription_expired'
  end
end
