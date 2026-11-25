class Corporate::StartConversation
  def initialize(account:, actor:)
    @account = account
    @actor = actor
  end

  def perform(phone)
    raise Pundit::NotAuthorizedError unless %w[manager supervisor].include?(Corporate.role(@account, @actor))
    raise ArgumentError unless phone.match?(/\A\+[1-9]\d{6,14}\z/)

    recipient = Corporate::IntegrationClient.new.resolve(phone)
    external_account = recipient.fetch('external_account_id').to_s
    external_user = recipient.fetch('external_user_id').to_s
    raise ArgumentError unless external_account.length.between?(1, 100) && external_user.match?(/\A\d{1,30}\z/)

    conversation = @account.with_lock { reserve(recipient, phone, external_account, external_user) }
    if Corporate.crm_enabled?(@account)
      ownership = CustomerOwnership.find_by!(account: @account, contact_id: conversation.contact_id)
      Corporate::CrmLookupJob.perform_later(@account.id, conversation.id, @actor.id, ownership.lock_version)
    end
    conversation
  end

  private

  def reserve(recipient, phone, external_account, external_user)
    identity = ChannelIdentity.find_by(account: @account, channel: 'telegram', external_account_id: external_account, external_user_id: external_user)
    unless identity
      contact = @account.contacts.create!(name: recipient['name'].presence || phone, phone_number: phone,
                                          identifier: "telegram/#{external_account}/#{external_user}")
      identity = ChannelIdentity.create!(account: @account, contact: contact, channel: 'telegram',
                                         external_account_id: external_account, external_user_id: external_user, verified_phone: phone)
    end
    contact = identity.contact
    if Corporate.role(@account, @actor) == 'manager'
      Corporate::OwnershipService.new(account: @account, actor: @actor).claim(contact: contact)
    else
      CustomerOwnership.find_or_create_by!(account: @account, contact: contact)
    end
    identity.update!(verified_phone: phone) if identity.verified_phone != phone
    contact.update!(phone_number: phone) if contact.phone_number != phone
    inbox = telegram_inbox

    contact_inbox = ContactInbox.find_or_create_by!(inbox: inbox, source_id: external_user) { |record| record.contact = contact }
    conversation_for(contact_inbox, contact, inbox)
  end

  def telegram_inbox
    inbox = @account.inboxes.find(ENV.fetch('CORPORATE_INBOX_ID'))
    raise ArgumentError unless inbox.api?

    inbox
  end

  def conversation_for(contact_inbox, contact, inbox)
    conversation = contact_inbox.conversations.order(:id).last
    conversation ||= Conversation.create!(account: @account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                          additional_attributes: { corporate_channel: 'telegram' })
    conversation.reload
  end
end
