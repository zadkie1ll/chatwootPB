# Idempotent channel provisioning, without reading client messages or CRM writes.
raise 'Corporate CE required' unless Corporate.enabled? && !ChatwootApp.enterprise?

account = Account.find(ENV.fetch('CORPORATE_ACCOUNT_ID'))
inbox = account.inboxes.find_by(name: 'MAX Personal')
if inbox
  raise 'Unexpected MAX inbox type' unless inbox.api?
else
  channel = Channel::Api.create!(account: account, hmac_mandatory: true, secret: SecureRandom.hex(32), webhook_url: nil)
  inbox = Inbox.create!(account: account, channel: channel, name: 'MAX Personal', enable_auto_assignment: false)
end
puts JSON.generate({ max_inbox_id: inbox.id, client_messages_read: false, crm_mutations: false })
