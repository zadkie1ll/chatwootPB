class Corporate::Visibility
  def initialize(account, user)
    @account = account
    @user = user
    @role = Corporate.role(account, user)
  end

  def contacts
    return @account.contacts if @role == 'supervisor'
    return @account.contacts.none unless @role == 'manager'

    shared = @account.conversations.where(id: manual_conversation_ids).select(:contact_id)
    private_contacts.or(@account.contacts.where(id: shared))
  end

  def conversations
    return @account.conversations if @role == 'supervisor'
    return @account.conversations.none unless @role == 'manager'

    @account.conversations.where(contact_id: private_contacts.select(:id)).or(@account.conversations.where(id: manual_conversation_ids))
  end

  def self.shared_conversations(account)
    manual = CorporateConversationShare.where(account: account).select(:conversation_id)
    absent_owners = absent_members(account).select(:user_id)
    contacts = CustomerOwnership.where(account: account, owner_id: absent_owners).select(:contact_id)
    account.conversations.where(id: manual).or(account.conversations.where(contact_id: contacts))
  end

  def self.absent_members(account)
    CorporateMembership.where(account: account, role: 'manager', active: true, chats_shared_while_absent: true)
  end

  private

  def manual_conversation_ids
    CorporateConversationShare.where(account: @account).select(:conversation_id)
  end

  def private_contacts
    ownerships = CustomerOwnership.where(account: @account, owner_id: @user.id)
    ownerships = ownerships.or(CustomerOwnership.where(account: @account, owner_id: self.class.absent_members(@account).select(:user_id)))
    ownerships = ownerships.or(CustomerOwnership.where(account: @account, shared_unidentified: true)) if Corporate.shared_intake_enabled?(@account)
    @account.contacts.where(id: ownerships.select(:contact_id))
  end
end
