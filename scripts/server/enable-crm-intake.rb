raise 'Corporate CE required' unless Corporate.enabled? && !ChatwootApp.enterprise?
account = Account.find(ENV.fetch('CORPORATE_ACCOUNT_ID'))
raise 'Shared intake flag is disabled' unless Corporate.shared_intake_enabled?(account)
count = Corporate::SharedIntakeBackfill.new(account).perform
puts JSON.generate({ shared_unassigned_hidden_phone_contacts: count, owned_and_previously_owned_clients_preserved: true })
