# Run once after deployment. Only technical counts are printed.
raise 'Explicit inbound recovery confirmation required' unless ENV['CONFIRM_INBOUND_RECOVERY'] == 'approved'

account = Account.find(ENV.fetch('CORPORATE_ACCOUNT_ID'))
service = Corporate::InboundIntake.new(account)
report = { examined: 0, opened: 0, lookups_enqueued: 0 }
CustomerOwnership.where(account: account, owner_id: nil).order(:id).limit(100).each do |ownership|
  conversations = account.conversations.where(contact_id: ownership.contact_id)
  message = account.messages.incoming.where(conversation_id: conversations.select(:id)).order(id: :desc).first
  next unless message

  conversation = message.conversation
  identity = ChannelIdentity.find_by(account: account, contact_id: ownership.contact_id,
                                     channel: Corporate::Channels.for_conversation(conversation))
  next unless identity

  report[:examined] += 1
  was_shared = ownership.shared_unidentified?
  lookup = service.received(identity, { direction: 'incoming', event_type: 'received' })
  report[:opened] += 1 if !was_shared && ownership.reload.shared_unidentified?
  if lookup
    Corporate::CrmInboundLookupJob.perform_later(account.id, conversation.id)
    report[:lookups_enqueued] += 1
  end
end
puts report.to_json
