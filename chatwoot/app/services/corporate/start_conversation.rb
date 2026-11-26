class Corporate::StartConversation
  def initialize(account:, actor:)
    @account = account
    @actor = actor
  end

  def perform(phone, channel: 'telegram')
    raise Pundit::NotAuthorizedError unless %w[manager supervisor].include?(Corporate.role(@account, @actor))

    raise ArgumentError unless Corporate::Channels::SUPPORTED.include?(channel)

    @channel = channel
    target = Corporate::Recipient.normalize(phone, channel: channel)
    recipient = Corporate::IntegrationClient.new.resolve(target, channel: channel)
    conversation = reserve_recipient(recipient, target)
    enqueue_crm_lookup(conversation)
    conversation
  end

  private

  def reserve_recipient(recipient, target)
    external_account = recipient.fetch('external_account_id').to_s
    external_user = recipient.fetch('external_user_id').to_s
    raise ArgumentError unless external_account.length.between?(1, 100) && external_user.match?(/\A\d{1,30}\z/)

    phone = target.start_with?('@') ? recipient['phone'].presence : target
    raise ArgumentError if phone && !phone.match?(/\A\+[1-9]\d{6,14}\z/)

    @recipient_label = target
    @account.with_lock { reserve(recipient, phone, external_account, external_user) }
  end

  def enqueue_crm_lookup(conversation)
    return unless Corporate.crm_enabled?(@account) && Corporate::Channels.crm_enabled?(@channel)

    if CorporateCrmLink.where(account: @account, contact_id: conversation.contact_id).where.not(external_deal_id: nil).exists?
      @account.with_lock { Corporate::ChannelContact.refresh_crm(@account, conversation) }
      return
    end

    ownership = CustomerOwnership.find_by!(account: @account, contact_id: conversation.contact_id)
    Corporate::CrmLookupJob.perform_later(@account.id, conversation.id, @actor.id, ownership.lock_version)
  end

  def reserve(recipient, phone, external_account, external_user)
    identity = ChannelIdentity.find_by(account: @account, channel: @channel, external_account_id: external_account, external_user_id: external_user)
    unless identity
      contact = Corporate::ChannelContact.find(@account, phone)
      contact ||= @account.contacts.create!(name: recipient['name'].presence || @recipient_label, phone_number: phone,
                                            identifier: "#{@channel}/#{external_account}/#{external_user}")
      identity = ChannelIdentity.create!(account: @account, contact: contact, channel: @channel,
                                         external_account_id: external_account, external_user_id: external_user, verified_phone: phone)
    end
    contact = identity.contact
    if Corporate.role(@account, @actor) == 'manager'
      Corporate::OwnershipService.new(account: @account, actor: @actor).claim(contact: contact)
    else
      CustomerOwnership.find_or_create_by!(account: @account, contact: contact)
    end
    update_phone(identity, contact, phone)
    inbox = Corporate::Channels.inbox(@account, @channel)

    contact_inbox = ContactInbox.find_or_create_by!(inbox: inbox, source_id: external_user) { |record| record.contact = contact }
    conversation_for(contact_inbox, contact, inbox)
  end

  def update_phone(identity, contact, phone)
    return if phone.blank?

    identity.update!(verified_phone: phone) if identity.verified_phone != phone
    contact.update!(phone_number: phone) if contact.phone_number != phone
  end

  def conversation_for(contact_inbox, contact, inbox)
    conversation = contact_inbox.conversations.order(:id).last
    conversation ||= Conversation.create!(account: @account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                          additional_attributes: { corporate_channel: @channel })
    conversation.reload
  end
end
