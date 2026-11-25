class RoomChannel < ApplicationCable::Channel
  def subscribed
    # TODO: should we only do ensure stream  if current account is present?
    # for now going ahead with guard clauses in update_subscription and broadcast_presence
    current_user
    current_account
    if Corporate.enabled? && (!@current_user.is_a?(User) || Corporate.membership(@current_account, @current_user).blank?)
      reject
      return
    end
    ensure_stream
    update_subscription
    broadcast_presence
  end

  def update_presence
    if Corporate.enabled? && (Corporate.membership(@current_account, @current_user).blank? ||
        !User.exists?(id: @current_user.id, pubsub_token: params[:pubsub_token]))
      stop_all_streams
      reject
      return
    end
    update_subscription
    broadcast_presence
  end

  private

  def broadcast_presence
    return if @current_account.blank?

    data = { account_id: @current_account.id, users: ::OnlineStatusTracker.get_available_users(@current_account.id) }
    if @current_user.is_a? User
      contacts = ::OnlineStatusTracker.get_available_contacts(@current_account.id)
      if Corporate.enabled?
        visible_ids = Corporate.contacts(@current_account, @current_user).pluck(:id).map(&:to_s)
        contacts = contacts.select { |id, _status| visible_ids.include?(id.to_s) }
      end
      data[:contacts] = contacts
      data[:work_preferences] = work_preferences
    end
    destination = Corporate.enabled? ? Corporate.stream(@current_account.id, @current_user.id) : pubsub_token
    ActionCable.server.broadcast(destination, { event: 'presence.update', data: data })
  end

  def work_preferences
    @current_user.account_users.find_by!(account_id: @current_account.id).slice(:accepts_conversations, :accepts_calls)
  end

  def ensure_stream
    if Corporate.enabled?
      stream_from Corporate.stream(@current_account.id, @current_user.id)
      return
    end
    stream_from pubsub_token
    stream_from "account_#{@current_account.id}" if @current_account.present? && @current_user.is_a?(User)
  end

  def update_subscription
    return if @current_account.blank?

    ::OnlineStatusTracker.update_presence(@current_account.id, @current_user.class.name, @current_user.id)
  end

  def pubsub_token
    @pubsub_token ||= params[:pubsub_token]
  end

  def current_user
    @current_user ||= if params[:user_id].blank?
                        ContactInbox.find_by!(pubsub_token: pubsub_token).contact
                      else
                        User.find_by!(pubsub_token: pubsub_token, id: params[:user_id])
                      end
  end

  def current_account
    return if current_user.blank?

    @current_account ||= if @current_user.is_a? Contact
                           @current_user.account
                         else
                           @current_user.accounts.find(params[:account_id])
                         end
  end
end
