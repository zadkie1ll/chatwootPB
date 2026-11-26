require 'corporate_helper'

RSpec.describe 'MAX corporate delivery', type: :request do
  let(:account) { Account.create!(name: 'Synthetic MAX') }
  let(:manager) { staff(account, 'manager') }
  let(:other) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:contact) { client(account, owner: manager) }
  let(:telegram_chat) { chat(account, contact) }
  let(:max_chat) do
    conversation = chat(account, contact)
    conversation.update!(additional_attributes: { corporate_channel: 'max' })
    conversation
  end
  let(:event) do
    { channel: 'max', external_account_id: '10', external_user_id: '20', external_chat_id: '30', external_message_id: '789',
      event_type: 'received', direction: 'incoming', text: 'Synthetic MAX', revision: '0000000000000001' }
  end

  def service_headers
    { 'Authorization' => "Bearer #{'s' * 64}" }
  end

  def identity
    ChannelIdentity.find_or_create_by!(account: account, contact: contact, channel: 'max', external_account_id: '10', external_user_id: '20')
  end

  it 'routes MAX to its own inbox and keeps Telegram receipt keys separate' do
    with_modified_env(CORPORATE_ACCOUNT_ID: account.id.to_s, CORPORATE_INBOX_ID: telegram_chat.inbox_id.to_s,
                      CORPORATE_MAX_INBOX_ID: max_chat.inbox_id.to_s, CW_SERVICE_TOKEN: 's' * 64) do
      post '/internal/corporate/ingest', params: { event: event }, headers: service_headers, as: :json
      expect(response).to have_http_status(:ok)
      message = Message.find(response.parsed_body['message_id'])
      expect(message.inbox_id).to eq(max_chat.inbox_id)
      expect(message.conversation.additional_attributes['corporate_channel']).to eq('max')
      post '/internal/corporate/ingest', params: { event: event }, headers: service_headers, as: :json
      expect(response.parsed_body['message_id']).to eq(message.id)
      expect(ChannelIdentity.find_by!(contact: message.conversation.contact).channel).to eq('max')
    end
  end

  it 'shares unidentified MAX inbound until it is assigned' do
    with_modified_env(CORPORATE_SHARED_INTAKE_ENABLED: 'true') do
      message = Corporate::IngestEvent.new(account: account, inbox: max_chat.inbox).perform(event, [])
      expect(Corporate.can_read?(account, manager, message)).to be(true)
      expect(Corporate.can_read?(account, other, message)).to be(true)
      Corporate::OwnershipService.new(account: account, actor: manager).claim(contact: message.conversation.contact)
      expect(Corporate.can_read?(account, other, message)).to be(false)
      expect(Corporate.can_read?(account, supervisor, message)).to be(true)
    end
  end

  it 'exports both inboxes and identifies the correct channel on each operation' do
    identity
    ChannelIdentity.create!(account: account, contact: contact, channel: 'telegram', external_account_id: '10', external_user_id: '20')
    max_message = Messages::MessageBuilder.new(manager, max_chat, ActionController::Parameters.new(content: 'MAX text')).perform
    telegram_message = Messages::MessageBuilder.new(manager, telegram_chat, ActionController::Parameters.new(content: 'Telegram text')).perform
    with_modified_env(CORPORATE_ACCOUNT_ID: account.id.to_s, CORPORATE_INBOX_ID: telegram_chat.inbox_id.to_s,
                      CORPORATE_MAX_INBOX_ID: max_chat.inbox_id.to_s, CW_SERVICE_TOKEN: 's' * 64) do
      get '/internal/corporate/outbox', headers: service_headers
      rows = response.parsed_body['operations'].index_by { |row| row['message_id'] }
      expect(rows.fetch(max_message.id)['channel']).to eq('max')
      expect(rows.fetch(telegram_message.id)['channel']).to eq('telegram')
    end
  end

  it 'rejects a MAX chat identifier which does not match the personal peer' do
    expect { Corporate::IngestEvent.new(account: account, inbox: max_chat.inbox).perform(event.merge(external_chat_id: '99'), []) }
      .to raise_error(ArgumentError)
  end

  it 'keeps a Telegram deletion tombstone from hiding a MAX message' do
    service = Corporate::IngestEvent.new(account: account, inbox: max_chat.inbox)
    telegram_event = event.merge(channel: 'telegram', external_chat_id: '20', event_type: 'deleted')
    service.perform(telegram_event, [])
    expect(service.perform(event, []).content).to eq('Synthetic MAX')
  end

  it 'looks up MAX phones for outbound CRM instead of requiring a Telegram identity' do
    mapping = CorporateCrmEmployee.create!(account: account, user: manager, external_user_id: '11')
    identity.update!(verified_phone: '+79990000000')
    service = instance_double(Corporate::CrmLinkService, bind: true)
    allow(Corporate::CrmLinkService).to receive(:new).and_return(service)
    with_modified_env(BITRIX_ENABLED: 'true', MAX_CRM_ENABLED: 'true') do
      Corporate::CrmLookupJob.perform_now(account.id, max_chat.id, manager.id, CustomerOwnership.find_by!(contact: contact).lock_version)
    end
    expect(mapping.external_user_id).to eq('11')
    expect(service).to have_received(:bind).with(conversation: max_chat, phone: '+79990000000', source: 'outbound', expected_version: 0)
  end

  it 'rejects multiple MAX attachments at the API boundary before creating a delivery' do
    params = ActionController::Parameters.new(message_type: 'outgoing', attachments: [Object.new, Object.new])
    expect { Corporate::MessageSafety.validate!(manager, max_chat, params) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(CorporateDelivery.count).to eq(0)
  end

  it 'accepts a harmless Apple Numbers document while retaining MIME checks' do
    path = Rails.root.join('spec/fixtures/files/synthetic-max.numbers')
    expect(Corporate::FileTypes.allowed?(File.binread(path), 'synthetic-max.numbers', 'application/octet-stream')).to be(true)
    expect(Corporate::FileTypes.allowed?('<script>unsafe()</script>', 'synthetic-max.numbers', 'text/html')).to be(false)
  end

  it 'retries automatic lookup when a prior lookup did not find a CRM record' do
    identity
    CorporateCrmLink.create!(account: account, contact: contact, conversation: max_chat, actor: manager,
                            sync_state: 'not_found', operation_id: SecureRandom.uuid)
    recipient = { 'external_account_id' => '10', 'external_user_id' => '20', 'name' => 'Synthetic' }
    integration = instance_double(Corporate::IntegrationClient)
    allow(Corporate::IntegrationClient).to receive(:new).and_return(integration)
    allow(integration).to receive(:resolve).with('+79990000000', channel: 'max').and_return(recipient)
    allow(Corporate::CrmLookupJob).to receive(:perform_later)
    opened = nil
    with_modified_env(BITRIX_ENABLED: 'true', MAX_CRM_ENABLED: 'true', CORPORATE_MAX_INBOX_ID: max_chat.inbox_id.to_s) do
      opened = Corporate::StartConversation.new(account: account, actor: manager).perform('+79990000000', channel: 'max')
    end
    expect(Corporate::CrmLookupJob).to have_received(:perform_later).with(account.id, opened.id, manager.id, 0)
  end

  context 'when a customer uses both messengers' do
    let(:account) { Account.create!(name: 'Synthetic cross messenger') }
    let(:manager) { staff(account, 'manager') }

    it 'reuses the verified Telegram contact, owner and CRM record for MAX' do
      contact = client(account, owner: manager)
      telegram = chat(account, contact)
      ChannelIdentity.create!(account: account, contact: contact, channel: 'telegram', external_account_id: 'tg', external_user_id: '44',
                              verified_phone: '+79990000000')
      max_inbox = chat(account, client(account)).inbox
      event = { channel: 'max', external_account_id: '10', external_user_id: '20', external_chat_id: '30', external_message_id: '501',
                event_type: 'received', direction: 'incoming', text: 'Synthetic MAX', phone: '+79990000000' }
      message = Corporate::IngestEvent.new(account: account, inbox: max_inbox).perform(event, [])
      expect(message.conversation.contact_id).to eq(contact.id)
      expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(manager.id)
      expect(Corporate::Channels.identity(message.conversation).channel).to eq('max')
      expect(message.inbox_id).not_to eq(telegram.inbox_id)
    end
  end
end
