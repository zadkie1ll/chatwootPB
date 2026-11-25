raise 'Corporate CE required' unless Corporate.enabled? && !ChatwootApp.enterprise?
account = Account.find(ENV.fetch('CORPORATE_ACCOUNT_ID'))
inbox = account.inboxes.find(ENV.fetch('CORPORATE_INBOX_ID'))
updated = 0
account.conversations.where(inbox: inbox).find_each do |conversation|
  next if conversation.additional_attributes['corporate_channel'].present?

  conversation.update!(additional_attributes: conversation.additional_attributes.merge('corporate_channel' => 'telegram'))
  updated += 1
end
puts JSON.generate({ existing_telegram_chats_labeled: updated, message_content_changed: false })
