require 'corporate_helper'

RSpec.describe Corporate::Recipient do
  it 'normalizes pasted Russian phone formats without silently truncating invalid numbers' do
    ['8 (999) 123-45-67', '79991234567', '9991234567', '+7 (999) 123-45-67'].each do |input|
      expect(described_class.normalize(input, channel: 'max')).to eq('+79991234567')
    end
    ['+7 (999) 123-45-6', '899912345678', '+15551234567', 'номер 89991234567', ''].each do |input|
      expect { described_class.normalize(input, channel: 'max') }.to raise_error(ArgumentError)
    end
  end

  it 'accepts Telegram usernames and links but never treats a username as a MAX phone' do
    ['@sample_user', 'sample_user', 'https://t.me/sample_user'].each do |input|
      expect(described_class.normalize(input, channel: 'telegram')).to eq('@sample_user')
      expect { described_class.normalize(input, channel: 'max') }.to raise_error(ArgumentError)
    end
  end
end

RSpec.describe Corporate::StartConversation do
  it 'preserves a verified contact phone when Telegram username lookup hides it' do
    account = Account.create!(name: 'Synthetic username lookup')
    manager = staff(account, 'manager')
    contact = client(account, owner: manager)
    contact.update!(phone_number: '+79990000000')
    conversation = chat(account, contact)
    identity = ChannelIdentity.create!(account: account, contact: contact, channel: 'telegram', external_account_id: '10',
                                       external_user_id: '20', verified_phone: '+79990000000')
    integration = instance_double(Corporate::IntegrationClient)
    allow(Corporate::IntegrationClient).to receive(:new).and_return(integration)
    allow(integration).to receive(:resolve).with('@sample_user', channel: 'telegram')
                                          .and_return('external_account_id' => '10', 'external_user_id' => '20', 'name' => 'Synthetic')
    with_modified_env(BITRIX_ENABLED: 'false', CORPORATE_INBOX_ID: conversation.inbox_id.to_s) do
      opened = described_class.new(account: account, actor: manager).perform('https://t.me/sample_user')
      expect(opened.contact_id).to eq(contact.id)
    end
    expect(identity.reload.verified_phone).to eq('+79990000000')
    expect(contact.reload.phone_number).to eq('+79990000000')
  end
end
