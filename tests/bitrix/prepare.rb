# Reset only synthetic CRM links in the dedicated local baseline account.
raise 'Mock gateway required' unless ENV.fetch('TELEGRAM_MODE') == 'mock'
raise 'Lab database required' unless ActiveRecord::Base.connection_db_config.database == 'chatwoot_lab'
account = Account.find(ENV.fetch('CORPORATE_ACCOUNT_ID'))
raise 'Synthetic account required' unless account.name == 'Stage 1 Synthetic Lab'
CorporateCrmLink.where(account: account).destroy_all
# Restore only the fixed synthetic outbound fixture between repeated test runs.
contacts = account.contacts.where(phone_number: ['+79991234567', '+79990000111'])
manager = account.users.find_by(email: 'lab-a@example.invalid')
if manager
  contacts.each do |contact|
    Corporate::OwnershipService.new(account: account, actor: nil).sync_from_crm(contact: contact, owner_id: manager.id)
  end
end
Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
puts 'Synthetic CRM links reset; no real portal or production data accessed.'
