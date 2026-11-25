require 'corporate_helper'

RSpec.describe 'Corporate reliable delivery and editing', type: :request do
  let(:account) { Account.create!(name: 'Synthetic reliable pipeline') }
  let(:manager) { staff(account, 'manager') }
  let(:other) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:contact) { client(account, owner: manager) }
  let(:conversation) { chat(account, contact) }

  def upload(value = 'Synthetic safe attachment')
    file = Tempfile.new(['synthetic', '.txt'])
    file.write(value)
    file.close
    Rack::Test::UploadedFile.new(file.path, 'text/plain')
  end

  def auth(user)
    { 'Authorization' => "Bearer #{user.access_token.token}" }
  end

  def identity
    ChannelIdentity.create!(account: account, contact: contact, channel: 'telegram', external_account_id: 'mock', external_user_id: '11')
  end

  def sent_message
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Original synthetic text')).perform
    CorporateDelivery.find_by!(message: message).set_state!('sent', external_id: '123')
    message.reload
  end

  it 'quarantines private-note files and releases only a clean scanned file' do
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Private synthetic', private: true,
                                                                                                   attachments: [upload])).perform
    file = message.attachments.first
    get "/api/v1/corporate_files/#{file.id}", headers: auth(supervisor)
    expect(response).to have_http_status(:locked)
    allow(Corporate::Antivirus).to receive(:scan).and_return(true)
    Corporate::AttachmentScanJob.perform_now(file.id)
    get "/api/v1/corporate_files/#{file.id}", headers: auth(supervisor)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('Synthetic safe attachment')
  end

  it 'keeps an infected note file unavailable and preserves the text' do
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Preserved note', private: true,
                                                                                                   attachments: [
                                                                                                     upload('EICAR-STANDARD-ANTIVIRUS-TEST-FILE')
                                                                                                   ])).perform
    file = message.attachments.first
    allow(Corporate::Antivirus).to receive(:scan).and_return(false)
    Corporate::AttachmentScanJob.perform_now(file.id)
    get "/api/v1/corporate_files/#{file.id}", headers: auth(supervisor)
    expect(response).to have_http_status(:locked)
    expect(message.reload.content).to eq('Preserved note')
    expect(message.content_attributes['corporate_attachments_state']).to eq('rejected')
  end

  it 'fetches new pending operations despite fifty older unknown outcomes' do
    identity
    message = sent_message
    50.times do |n|
      CorporateDelivery.create!(account: account, message: message, actor: manager, assignment_version: 0, state: 'unknown', action: 'edit',
                                revision: n + 1)
    end
    pending = CorporateDelivery.create!(account: account, message: message, actor: manager, assignment_version: 0, action: 'edit', revision: 51)
    with_modified_env(CORPORATE_ACCOUNT_ID: account.id.to_s, CORPORATE_INBOX_ID: conversation.inbox_id.to_s, CW_SERVICE_TOKEN: 's' * 64) do
      get '/internal/corporate/outbox', headers: { 'Authorization' => "Bearer #{'s' * 64}" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['operations'].pluck('operation_id')).to include(pending.operation_id)
    end
  end

  it 'edits the same Telegram message only after acknowledgement and forbids another manager' do
    identity
    message = sent_message
    path = "/api/v1/accounts/#{account.id}/corporate/conversations/#{conversation.display_id}/messages/#{message.id}/edit"
    put path, params: { content: 'Forbidden' }, headers: auth(other)
    expect(response).to have_http_status(:not_found)
    put path, params: { content: 'Changed synthetic' }, headers: auth(manager)
    expect(response).to have_http_status(:accepted)
    expect(message.reload.content).to eq('Original synthetic text')
    operation = CorporateDelivery.find_by!(message: message, action: 'edit')
    expect(operation.requested_content).to eq('Changed synthetic')
    operation.set_state!('sent', external_id: '123')
    expect(message.reload.content).to eq('Changed synthetic')
    expect(message.source_id).to eq('123')
  end

  it 'preserves an incoming text while media is pending and attaches the later verified file once' do
    identity
    event = { channel: 'telegram', external_account_id: 'mock', external_user_id: '11', external_chat_id: '11', external_message_id: '789',
              event_type: 'received', direction: 'incoming', text: 'Text first', revision: '', attachment_state: 'pending', media_id: '42' }
    service = Corporate::IngestEvent.new(account: account, inbox: conversation.inbox)
    message = service.perform(event, [])
    expect(message.content).to eq('Text first')
    media = event.merge(event_type: 'media', source_revision: '', revision: '/media', attachment_state: 'ready')
    service.perform(media, [upload])
    service.perform(media, [upload])
    expect(message.reload.attachments.count).to eq(1)
    expect(message.attachments.first.meta['scan_state']).to eq('clean')
    expect(message.content).to eq('Text first')
  end

  it 'rejects active content disguised as an allowed image type' do
    data = '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    expect(Corporate::FileTypes.allowed?(data, 'synthetic.png', 'image/png')).to be(false)
  end

  it 'moves a converted lead to its deal and follows the CRM owner without echoing an assignment' do
    CorporateCrmEmployee.create!(account: account, user: manager, external_user_id: '11')
    CorporateCrmEmployee.create!(account: account, user: other, external_user_id: '22')
    link = CorporateCrmLink.create!(account: account, contact: contact, conversation: conversation, actor: manager,
                                    entity_type: 'lead', external_deal_id: '901', operation_id: SecureRandom.uuid, sync_state: 'applied',
                                    deal_url: 'https://crm.example.test/crm/lead/details/901/')
    version = CustomerOwnership.find_by!(contact: contact).lock_version
    with_modified_env(BITRIX_ENABLED: 'true', CORPORATE_ACCOUNT_ID: account.id.to_s, CORPORATE_INBOX_ID: conversation.inbox_id.to_s,
                      CW_SERVICE_TOKEN: 's' * 64) do
      post '/internal/corporate/crm/target', params: { id: link.id, operation_id: link.operation_id, assignment_version: version,
                                                       deal_id: '902', assigned_user_id: '22', title: 'Converted synthetic deal' },
                                             headers: { 'Authorization' => "Bearer #{'s' * 64}" }
      expect(response).to have_http_status(:no_content)
      expect(link.reload.entity_type).to eq('deal')
      expect(link.deal_url).to eq('https://crm.example.test/crm/deal/details/902/')
      expect(link.sync_payload).not_to have_key('assigned_user_id')
      expect(Corporate.can_read?(account, manager, conversation)).to be(false)
      expect(Corporate.can_read?(account, other, conversation)).to be(true)
    end
  end

  it 'keeps a file locked through scanner outage and releases it after recovery' do
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Synthetic retry', private: true,
                                                                                                   attachments: [upload])).perform
    file = message.attachments.first
    allow(Corporate::Antivirus).to receive(:scan).and_raise(Corporate::Antivirus::Unavailable)
    Corporate::AttachmentScanJob.perform_now(file.id)
    get "/api/v1/corporate_files/#{file.id}", headers: auth(manager)
    expect(response).to have_http_status(:locked)
    allow(Corporate::Antivirus).to receive(:scan).and_return(true)
    Corporate::AttachmentScanJob.perform_now(file.id)
    get "/api/v1/corporate_files/#{file.id}", headers: auth(manager)
    expect(response).to have_http_status(:ok)
  end

  it 'revokes a manager immediately even if CRM ownership reconciliation is unresolved' do
    CorporateCrmLink.create!(account: account, contact: contact, conversation: conversation, actor: manager,
                             external_deal_id: '991', operation_id: SecureRandom.uuid, sync_state: 'unknown')
    Corporate::StaffService.new(account: account, actor: supervisor).disable(manager.id)
    expect(Corporate.role(account, manager)).to be_nil
    expect(Corporate.can_read?(account, manager, conversation)).to be(false)
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(manager.id)
  end
end
