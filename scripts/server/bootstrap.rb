# Initial staff only, no client data or Telegram session is created here.
raise 'Corporate CE required' unless Corporate.enabled? && !ChatwootApp.enterprise?
expected_account = ENV.fetch('CORPORATE_ACCOUNT_ID').to_i
expected_inbox = ENV.fetch('CORPORATE_INBOX_ID').to_i
account = Account.find_by(id: expected_account)
raise 'Unexpected existing account' if account && account.name != ENV.fetch('COMPANY_NAME')
account ||= Account.create!(name: ENV.fetch('COMPANY_NAME'), locale: :ru)
raise 'Account ID differs from prepared config' unless account.id == expected_account

[['SUPERVISOR', 'supervisor', 'Руководитель'], ['TECH_ADMIN', 'technical_admin', 'Технический администратор']].each do |key, role, name|
  email = ENV.fetch("INITIAL_#{key}_EMAIL")
  user = User.find_by(email: email)
  unless user
    user = User.new(email: email, name: name, password: ENV.fetch("INITIAL_#{key}_PASSWORD"))
    user.skip_confirmation!
    user.save!
  end
  account.account_users.find_or_create_by!(user: user).update!(role: role == 'technical_admin' ? :administrator : :agent)
  CorporateMembership.find_or_initialize_by(account: account, user: user).update!(role: role, active: true)
end
inbox = account.inboxes.find_by(id: expected_inbox)
unless inbox
  channel = Channel::Api.create!(account: account, hmac_mandatory: true, secret: ENV.fetch('CW_WEBHOOK_SECRET'),
                                 webhook_url: nil)
  inbox = Inbox.create!(account: account, channel: channel, name: 'Telegram Personal', enable_auto_assignment: false)
end
raise 'Inbox ID differs from prepared config' unless inbox.id == expected_inbox
Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
puts 'Initial corporate roles/channel prepared. Credentials remain in server .env. No Telegram login performed.'
