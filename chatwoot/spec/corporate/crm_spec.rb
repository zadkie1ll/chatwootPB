require 'corporate_helper'

RSpec.describe 'Corporate CRM linking and shared intake', type: :request do
  let(:account) { Account.create!(name: 'Synthetic CRM') }
  let(:manager_a) { staff(account, 'manager') }
  let(:manager_b) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:technical) { staff(account, 'technical_admin') }
  let(:contact) { client(account) }
  let(:conversation) { chat(account, contact) }
  let(:result) do
    { 'found' => true, 'deal_id' => '502', 'assigned_user_id' => '22', 'title' => 'Synthetic deal',
      'deal_url' => 'https://crm.example.test/crm/deal/details/502/', 'phone' => '+79991234567' }
  end
  let(:crm) { instance_double(Corporate::CrmClient) }

  around do |example|
    with_modified_env(BITRIX_ENABLED: 'true', CORPORATE_SHARED_INTAKE_ENABLED: 'true') { example.run }
  end

  def auth(user)
    { 'Authorization' => "Bearer #{user.access_token.token}" }
  end

  def make_shared
    CustomerOwnership.find_by!(contact: contact).update!(shared_unidentified: true)
  end

  def map_manager(user, external_id)
    CorporateCrmEmployee.create!(account: account, user: user, external_user_id: external_id)
  end

  before do
    allow(Corporate::CrmClient).to receive(:new).and_return(crm)
    allow(crm).to receive(:call).with('resolve', anything).and_return(result)
  end

  it 'shares only the explicit unidentified pool with active managers' do
    make_shared
    expect(Corporate.can_read?(account, manager_a, conversation)).to be(true)
    expect(Corporate.can_read?(account, manager_b, conversation)).to be(true)
    expect(Corporate.can_read?(account, technical, conversation)).to be(false)
    with_modified_env(CORPORATE_SHARED_INTAKE_ENABLED: 'false') do
      expect(Corporate.can_read?(account, manager_b, conversation)).to be(false)
    end
    other_account = Account.create!(name: 'Foreign')
    expect(Corporate.can_read?(other_account, manager_a, conversation)).to be(false)
  end

  it 'allows both managers to reply before binding without assigning the client' do
    make_shared
    [manager_a, manager_b].each do |user|
      message = Messages::MessageBuilder.new(user, conversation, ActionController::Parameters.new(content: 'Synthetic shared reply')).perform
      expect(CorporateDelivery.find_by!(message: message).actor_id).to eq(user.id)
    end
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to be_nil
  end

  it 'links to the initiating manager and revokes other managers at every read' do
    make_shared
    map_manager(manager_a, '11')
    map_manager(manager_b, '22')
    message = conversation.messages.create!(account: account, inbox: conversation.inbox, sender: contact,
                                            content: 'Synthetic file', message_type: :incoming)
    attachment = message.attachments.create!(account: account, file_type: :file)
    attachment.file.attach(io: StringIO.new('synthetic'), filename: 'test.txt', content_type: 'text/plain')
    attachment.update!(meta: { scan_state: 'clean' })
    get "/api/v1/corporate_files/#{attachment.id}", headers: auth(manager_b)
    expect(response).to have_http_status(:ok)
    link = Corporate::CrmLinkService.new(account: account, actor: manager_a).bind(conversation: conversation, phone: '+79991234567')
    expect(link.sync_payload['assigned_user_id']).to eq('11')
    expect(CustomerOwnership.find_by!(contact: contact)).not_to be_shared_unidentified
    expect(Corporate.can_read?(account, manager_b, conversation)).to be(false)
    expect(Corporate.can_read?(account, supervisor, conversation)).to be(true)
    get "/api/v1/corporate_files/#{attachment.id}", headers: auth(manager_b)
    expect(response).to have_http_status(:not_found)
    get "/api/v1/accounts/#{account.id}/corporate/crm/conversations/#{conversation.display_id}", headers: auth(manager_b)
    expect(response).to have_http_status(:not_found)
  end

  it 'does not let another manager steal an identified contact by linking a deal' do
    CustomerOwnership.find_by!(contact: contact).update!(owner: manager_a)
    map_manager(manager_b, '22')
    expect do
      Corporate::CrmLinkService.new(account: account, actor: manager_b).bind(conversation: conversation, deal_url: result['deal_url'])
    end.to raise_error(ActiveRecord::RecordNotFound)
    expect(crm).not_to have_received(:call)
  end

  it 'requires a unique active employee mapping before restricting the shared pool' do
    make_shared
    expect do
      Corporate::CrmLinkService.new(account: account, actor: manager_a).bind(conversation: conversation, phone: '+79991234567')
    end.to raise_error(Corporate::CrmClient::Error, 'crm_employee_not_mapped')
    expect(CustomerOwnership.find_by!(contact: contact)).to be_shared_unidentified
    expect(CorporateCrmLink.where(contact: contact)).to be_empty
    map_manager(manager_a, '11')
    expect { map_manager(manager_b, '11') }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'does not change ownership when no open CRM deal is found' do
    make_shared
    allow(crm).to receive(:call).with('resolve', anything).and_return('found' => false, 'phone' => '+79991234567')
    link = Corporate::CrmLinkService.new(account: account, actor: manager_a).bind(conversation: conversation, phone: '+79991234567')
    expect(link.sync_state).to eq('not_found')
    expect(CustomerOwnership.find_by!(contact: contact)).to be_shared_unidentified
  end

  it 'fences ownership changes while a CRM write has an unresolved outcome' do
    make_shared
    map_manager(manager_a, '11')
    map_manager(manager_b, '22')
    link = Corporate::CrmLinkService.new(account: account, actor: manager_a).bind(conversation: conversation, phone: '+79991234567')
    link.update!(sync_state: 'unknown')
    expect do
      Corporate::OwnershipService.new(account: account, actor: supervisor).transfer(contact: contact, owner_id: manager_b.id, reason: 'Synthetic')
    end.to raise_error(Corporate::DispatchInProgress)
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(manager_a.id)
  end

  it 'discards an obsolete outgoing lookup after a transfer' do
    CustomerOwnership.find_by!(contact: contact).update!(owner: manager_a)
    old_version = CustomerOwnership.find_by!(contact: contact).lock_version
    Corporate::OwnershipService.new(account: account, actor: supervisor).transfer(contact: contact, owner_id: manager_b.id, reason: 'Synthetic')
    Corporate::CrmLookupJob.perform_now(account.id, conversation.id, manager_a.id, old_version)
    expect(crm).not_to have_received(:call)
  end

  it 'routes a visible-phone incoming to the mapped CRM owner without rewriting that owner' do
    map_manager(manager_b, '22')
    contact.update!(phone_number: '+79991234567')
    Corporate::CrmInboundLookupJob.perform_now(account.id, conversation.id)
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(manager_b.id)
    expect(CorporateCrmLink.find_by!(contact: contact).sync_payload).not_to have_key('assigned_user_id')
    audit = AssignmentAudit.find_by!(contact: contact)
    expect(audit.source).to eq('bitrix24')
    expect(audit.actor_id).to be_nil
  end

  it 'denies employee mapping to managers and technical administrators' do
    [manager_a, technical].each do |user|
      get "/api/v1/accounts/#{account.id}/corporate/crm/employees", headers: auth(user)
      expect(response).to have_http_status(:not_found)
    end
    expect(crm).not_to have_received(:call)
  end

  it 'distinguishes hidden phones from known phones on new incoming identities' do
    event = { channel: 'telegram', external_account_id: '123', external_user_id: '456', external_chat_id: '456',
              external_message_id: '789', event_type: 'received', direction: 'incoming', text: 'Synthetic' }
    service = Corporate::IngestEvent.new(account: account, inbox: conversation.inbox)
    hidden = service.perform(event, [])
    known = service.perform(event.merge(external_user_id: '457', external_chat_id: '457', phone: '+79991234567'), [])
    expect(CustomerOwnership.find_by!(contact: hidden.conversation.contact)).to be_shared_unidentified
    expect(CustomerOwnership.find_by!(contact: known.conversation.contact)).not_to be_shared_unidentified
    expect(known.conversation.contact.phone_number).to eq('+79991234567')
  end

  it 'only backfills never-owned unknown incoming clients without pending delivery' do
    ChannelIdentity.create!(account: account, contact: contact, channel: 'telegram', external_account_id: '123', external_user_id: '456')
    conversation.messages.create!(account: account, inbox: conversation.inbox, sender: contact, content: 'Synthetic', message_type: :incoming)
    expect(Corporate::SharedIntakeBackfill.new(account).perform).to eq(1)
    ownership = CustomerOwnership.find_by!(contact: contact)
    expect(ownership).to be_shared_unidentified
    ownership.update!(shared_unidentified: false)
    Corporate::OwnershipService.new(account: account, actor: supervisor).transfer(contact: contact, owner_id: manager_a.id, reason: 'Synthetic')
    Corporate::OwnershipService.new(account: account, actor: supervisor).transfer(contact: contact, owner_id: nil, reason: 'Synthetic release')
    expect(Corporate::SharedIntakeBackfill.new(account).perform).to eq(0)
    expect(ownership.reload).not_to be_shared_unidentified
  end

  it 'keeps a different account out of the configured CRM portal' do
    with_modified_env(CORPORATE_ACCOUNT_ID: (account.id + 1).to_s) do
      expect(Corporate.crm_enabled?(account)).to be(false)
      get "/api/v1/accounts/#{account.id}/corporate/crm/employees", headers: auth(supervisor)
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'follows a CRM responsible change with a version fence and no write-back loop' do
    make_shared
    map_manager(manager_a, '11')
    map_manager(manager_b, '22')
    link = Corporate::CrmLinkService.new(account: account, actor: manager_a).bind(conversation: conversation, phone: '+79991234567')
    link.update!(sync_state: 'applied')
    version = CustomerOwnership.find_by!(contact: contact).lock_version
    payload = { id: link.id, operation_id: link.operation_id, assignment_version: version, external_user_id: '22' }
    with_modified_env(CORPORATE_ACCOUNT_ID: account.id.to_s, CORPORATE_INBOX_ID: conversation.inbox_id.to_s, CW_SERVICE_TOKEN: 's' * 64) do
      post '/internal/corporate/crm/owner', params: payload, headers: { 'Authorization' => "Bearer #{'s' * 64}" }
      expect(response).to have_http_status(:no_content)
      expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(manager_b.id)
      expect(link.reload.operation_id).to eq(payload[:operation_id])
      expect(link.sync_state).to eq('applied')
      post '/internal/corporate/crm/owner', params: payload.merge(external_user_id: '11'), headers: { 'Authorization' => "Bearer #{'s' * 64}" }
      expect(response).to have_http_status(:conflict)
      expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(manager_b.id)
    end
  end
end
