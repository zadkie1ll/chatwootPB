class Corporate::BroadcastJob < ApplicationJob
  queue_as :critical

  CONTACT_EVENTS = %w[contact.created contact.updated contact.merged].freeze
  MESSAGE_EVENTS = %w[message.created message.updated first_reply.created].freeze
  CONVERSATION_EVENTS = %w[
    conversation.created conversation.updated conversation.status_changed conversation.read
    conversation.bot_handoff assignee.changed team.changed conversation.contact_changed
    conversation.typing_on conversation.typing_off conversation.mentioned
  ].freeze

  def perform(account_id, event_name, data)
    return unless Corporate.enabled?

    Current.corporate_read_cache = nil
    Current.corporate_absence_cache = nil
    account = Account.find_by(id: account_id)
    return unless account&.active?

    data = data.deep_symbolize_keys
    # Same lock as transfer: resolve current owner and rebuild payload at publication.
    account.with_lock do
      if %w[notification.created notification.updated].include?(event_name)
        publish_notification(account, event_name, data)
        return
      end
      resource = resource_for(account, event_name, data)
      return unless resource

      publish_resource(account, resource, event_name, data)
    end
  end

  private

  def publish_resource(account, resource, event_name, data)
    recipients(account, resource).each do |user|
      next unless Corporate.can_read?(account, user, resource)

      Corporate.with_user(account, user) do
        payload = payload_for(event_name, resource, data)
        ActionCable.server.broadcast(Corporate.stream(account.id, user.id), { event: event_name, data: payload.merge(account_id: account.id) })
      end
    end
  end

  def publish_notification(account, event_name, data)
    notification = account.notifications.find_by(id: data.dig(:notification, :id))
    return unless notification&.conversation && Corporate.can_read?(account, notification.user, notification.conversation)

    user = notification.user
    Corporate.with_user(account, user) do
      finder = NotificationFinder.new(user, account)
      payload = { notification: notification.push_event_data, unread_count: finder.unread_count, count: finder.count, account_id: account.id }
      ActionCable.server.broadcast(Corporate.stream(account.id, user.id), { event: event_name, data: payload })
    end
  end

  def resource_for(account, event_name, data)
    return account.contacts.find_by(id: data[:id]) if CONTACT_EVENTS.include?(event_name)
    return account.messages.find_by(id: data[:id]) if MESSAGE_EVENTS.include?(event_name)
    return unless CONVERSATION_EVENTS.include?(event_name)

    display_id = data.dig(:conversation, :id) || data[:id]
    account.conversations.find_by(display_id: display_id)
  end

  def recipients(account, resource)
    contact = if resource.is_a?(Contact)
                resource
              else
                (resource.is_a?(Message) ? resource.conversation.contact : resource.contact)
              end
    ownership = CustomerOwnership.find_by(account: account, contact: contact)
    memberships = CorporateMembership.where(account: account, active: true)
    managers = memberships.where(role: 'manager')
    managers = managers.where(user_id: ownership&.owner_id) unless shared_resource?(account, resource, contact, ownership)
    account.users.where(id: memberships.where(role: 'supervisor').or(managers).select(:user_id))
  end

  def shared_resource?(account, resource, contact, ownership)
    return true if Corporate.shared_intake_enabled?(account) && ownership&.shared_unidentified?

    shared = Corporate::Visibility.shared_conversations(account)
    return shared.exists?(contact_id: contact.id) if resource.is_a?(Contact)

    conversation = resource.is_a?(Message) ? resource.conversation : resource
    shared.exists?(id: conversation.id)
  end

  def payload_for(event_name, resource, previous)
    if event_name.start_with?('conversation.typing_')
      # The typing user is staff; never trust a historical conversation snapshot.
      { conversation: resource.push_event_data, user: previous[:user], is_private: previous[:is_private] }
    else
      resource.push_event_data
    end
  end
end
