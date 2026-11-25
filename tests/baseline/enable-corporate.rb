# One-time conversion of the synthetic baseline, never client data.
require 'json'
raise 'Wrong environment' unless Corporate.enabled? && ENV['LAB_SEED_CONFIRM'] == 'synthetic-only'
raise 'Wrong database' unless ActiveRecord::Base.connection_db_config.database == 'chatwoot_lab'

fixture = JSON.parse(File.read('/lab-secrets/baseline.json'))
account = Account.find(fixture.fetch('account_id'))
raise 'Not the synthetic lab' unless account.name == 'Stage 1 Synthetic Lab'

ActiveRecord::Base.transaction do
  { 'A' => 'manager', 'B' => 'manager', 'R' => 'supervisor', 'D' => 'manager' }.each do |label, role|
    user = User.find(fixture.fetch('users').fetch(label).fetch('id'))
    target_account = label == 'D' ? Account.find(fixture.fetch('other_account_id')) : account
    member = CorporateMembership.find_or_initialize_by(account: target_account, user: user)
    member.update!(role: role, active: true)
    target_account.account_users.find_by!(user: user).update!(role: :agent)
  end
  technical = User.find_or_initialize_by(email: 'lab-t@example.invalid')
  if technical.new_record?
    technical.name = 'Lab Technical Administrator'
    technical.password = ENV.fetch('LAB_USER_PASSWORD')
    technical.skip_confirmation!
    technical.save!
  end
  account.account_users.find_or_create_by!(user: technical).update!(role: :administrator)
  CorporateMembership.find_or_initialize_by(account: account, user: technical).update!(role: 'technical_admin', active: true)
  fixture['users']['T'] = { id: technical.id, email: technical.email, token: technical.access_token.token, pubsub_token: technical.pubsub_token }

  fixture.fetch('contacts').each do |label, contact_id|
    contact = Contact.find(contact_id)
    owner_label = { 'X' => 'A', 'Y' => 'B', 'Q' => 'D' }[label]
    owner_id = owner_label && fixture.fetch('users').fetch(owner_label).fetch('id')
    ownership = CustomerOwnership.find_or_initialize_by(account_id: contact.account_id, contact: contact)
    ownership.update!(owner_id: owner_id, assigned_at: owner_id && Time.current)
    contact.conversations.each { |conversation| conversation.update!(assignee_id: owner_id) }
  end
end
File.write('/lab-secrets/baseline.json', JSON.pretty_generate(fixture))
puts 'Synthetic corporate roles/ownership prepared; no credentials printed.'
