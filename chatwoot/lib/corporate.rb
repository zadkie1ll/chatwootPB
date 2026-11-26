# Independent Community Edition business policy. No Enterprise modules are used.
module Corporate
  class DispatchInProgress < StandardError
  end

  class ChannelUnavailable < StandardError
  end

  def self.enabled?
    ENV['CORPORATE_ACCESS_ENABLED'] == 'true'
  end

  def self.crm_enabled?(account = nil)
    configured = ENV['CORPORATE_ACCOUNT_ID'].presence
    enabled? && ENV['BITRIX_ENABLED'] == 'true' && (account.nil? || configured.nil? || configured == account.id.to_s)
  end

  def self.shared_intake_enabled?(account = nil)
    configured = ENV['CORPORATE_ACCOUNT_ID'].presence
    enabled? && ENV['CORPORATE_SHARED_INTAKE_ENABLED'] == 'true' && (account.nil? || configured.nil? || configured == account.id.to_s)
  end

  def self.membership(account, user)
    return unless user.is_a?(User) && account&.active?
    return unless AccountUser.exists?(account_id: account.id, user_id: user.id)

    CorporateMembership.find_by(account_id: account.id, user_id: user.id, active: true)
  end

  def self.role(account, user)
    membership(account, user)&.role
  end

  def self.contacts(account, user)
    Corporate::Visibility.new(account, user).contacts
  end

  def self.conversations(account, user)
    Corporate::Visibility.new(account, user).conversations
  end

  def self.can_read?(account, user, record)
    return false if record.blank? || record.account_id != account.id

    case record
    when Contact
      contacts(account, user).exists?(id: record.id)
    when Conversation
      conversations(account, user).exists?(id: record.id)
    when Message
      conversations(account, user).exists?(id: record.conversation_id)
    else
      false
    end
  end

  def self.with_user(account, user)
    previous = [Current.account, Current.user, Current.account_user]
    Current.account = account
    Current.user = user
    Current.account_user = account.account_users.find_by(user: user)
    yield
  ensure
    Current.account, Current.user, Current.account_user = previous
  end

  def self.stream(account_id, user_id)
    "corporate_account_#{account_id}_user_#{user_id}_#{User.find(user_id).pubsub_token}"
  end
end
