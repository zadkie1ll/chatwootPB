# Synthetic local lab only. Run with the lab-seed Compose service.
require 'json'
require 'stringio'

raise 'Synthetic lab confirmation required' unless ENV['LAB_SEED_CONFIRM'] == 'synthetic-only'
raise 'Wrong database' unless ActiveRecord::Base.connection_db_config.database == 'chatwoot_lab'
raise 'Enterprise code must not be present' if Rails.root.join('enterprise').exist? || ChatwootApp.enterprise?
raise 'Unexpected upstream commit' unless Rails.root.join('.git_sha').read.strip == 'b2f94636d325a126a67c6c4c808303d8aa8cbeea'
raise 'Lab already seeded; do not overwrite credentials or data' if Account.exists?(name: 'Stage 1 Synthetic Lab')

password = ENV.fetch('LAB_USER_PASSWORD')
fixture = { version: 1, source_commit: Rails.root.join('.git_sha').read.strip, users: {}, contacts: {}, conversations: {} }

ActiveRecord::Base.transaction do
  account = Account.create!(name: 'Stage 1 Synthetic Lab', locale: :ru)
  other_account = Account.create!(name: 'Stage 1 Other Synthetic Account', locale: :ru)
  fixture[:account_id] = account.id
  fixture[:other_account_id] = other_account.id
  Current.account = account

  %w[A B R D].each do |label|
    user = User.new(name: "Lab #{label}", email: "lab-#{label.downcase}@example.invalid", password: password)
    user.skip_confirmation!
    user.save!
    user_account = label == 'D' ? other_account : account
    AccountUser.create!(account: user_account, user: user, role: label == 'R' ? :administrator : :agent)
    fixture[:users][label] = { id: user.id, email: user.email, token: user.access_token.token, pubsub_token: user.pubsub_token }
  end
  Current.user = User.find(fixture[:users]['R'][:id])
  Current.account_user = account.account_users.find_by!(user: Current.user)

  [[account, %w[A B R]], [other_account, %w[D]]].each do |target_account, labels|
    Current.account = target_account
    Current.user = User.find(fixture[:users][target_account == account ? 'R' : 'D'][:id])
    Current.account_user = target_account.account_users.find_by!(user: Current.user)
    channel = Channel::Api.create!(account: target_account, hmac_mandatory: true)
    inbox = Inbox.create!(account: target_account, channel: channel, name: 'Synthetic API Inbox', enable_auto_assignment: false)
    labels.each { |label| InboxMember.create!(inbox: inbox, user_id: fixture[:users][label][:id]) }
    fixture[target_account == account ? :inbox_id : :other_inbox_id] = inbox.id

    (target_account == account ? %w[X Y Z] : %w[Q]).each do |label|
      contact = Contact.create!(account: target_account, name: "Synthetic Client #{label}", identifier: "stage1-#{label.downcase}")
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: "stage1-#{label.downcase}")
      assignee_label = { 'X' => 'A', 'Y' => 'B', 'Q' => 'D' }[label]
      conversation = Conversation.create!(
        account: target_account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
        assignee_id: assignee_label && fixture[:users][assignee_label][:id], status: :open
      )
      message = Message.create!(
        account: target_account, inbox: inbox, conversation: conversation, sender: contact,
        message_type: :incoming, content: "Synthetic baseline message #{label}"
      )
      fixture[:contacts][label] = contact.id
      fixture[:conversations][label] = conversation.reload.display_id
      next unless label == 'X'

      attachment = message.attachments.create!(account: target_account, file_type: :file)
      attachment.file.attach(io: StringIO.new("SYNTHETIC STAGE 1 FILE\n"), filename: 'synthetic.txt', content_type: 'text/plain')
      fixture[:attachment_url] = attachment.file_url
    end
  end
end

File.open('/lab-secrets/baseline.json', File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  file.write(JSON.pretty_generate(fixture))
end
Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
Current.reset
puts 'Synthetic A/B/R and separate account created. Credentials saved to secrets/baseline.json (0600).'
