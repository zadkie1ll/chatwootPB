require 'corporate_helper'

RSpec.describe 'Corporate sharing', type: :request do
  let(:account) { Account.create!(name: 'Synthetic sharing') }
  let(:owner) { staff(account, 'manager') }
  let(:colleague) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:technical) { staff(account, 'technical_admin') }
  let(:contact) { client(account, owner: owner) }
  let(:conversation) { chat(account, contact) }
  let(:sibling) { chat(account, contact) }
  let(:service) { Corporate::SharingService.new(account: account, actor: owner) }

  before do
    conversation.update!(assignee: owner)
    sibling.update!(assignee: owner)
  end

  it 'shares only the selected conversation and allows colleagues to reply without transferring CRM ownership' do
    service.conversation(conversation, true)
    expect(Corporate.can_read?(account, colleague, conversation)).to be(true)
    expect(Corporate.can_read?(account, colleague, sibling)).to be(false)
    expect(Corporate.can_read?(account, technical, conversation)).to be(false)
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(owner.id)
    with_modified_env(CORPORATE_ACCOUNT_ID: account.id.to_s, CORPORATE_INBOX_ID: conversation.inbox_id.to_s) do
      message = Messages::MessageBuilder.new(colleague, conversation, ActionController::Parameters.new(content: 'Synthetic collaboration')).perform
      expect(message.sender).to eq(colleague)
      expect(CorporateDelivery.find_by!(message: message).actor).to eq(colleague)
    end
  end

  it 'does not let a reader reopen, close, or share somebody else’s private conversation' do
    service.conversation(conversation, true)
    reader = Corporate::SharingService.new(account: account, actor: colleague)
    expect { reader.conversation(conversation, false) }.to raise_error(ActiveRecord::RecordNotFound)
    expect { reader.conversation(sibling, true) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'opens all current and future owned chats while absent and closes only absence access on return' do
    service.absence(true)
    expect(Corporate.can_read?(account, colleague, sibling)).to be(true)
    future = chat(account, client(account, owner: owner))
    expect(Corporate.can_read?(account, colleague, future)).to be(true)
    service.conversation(conversation, true)
    service.absence(false)
    expect(Corporate.can_read?(account, colleague, conversation)).to be(true)
    expect(Corporate.can_read?(account, colleague, sibling)).to be(false)
    expect(Corporate.can_read?(account, colleague, future)).to be(false)
  end

  it 'cancels queued collaborator sends when sharing closes' do
    service.conversation(conversation, true)
    message = conversation.messages.create!(account: account, inbox: conversation.inbox, sender: colleague, message_type: :outgoing,
                                            content: 'Synthetic')
    delivery = CorporateDelivery.create!(account: account, message: message, actor: colleague, assignment_version: 0, state: 'pending')
    service.conversation(conversation, false)
    expect(delivery.reload.state).to eq('cancelled')
    expect(Corporate.can_read?(account, colleague, conversation)).to be(false)
  end

  it 'keeps access and audit unchanged if an uncertain collaborator send prevents closing' do
    service.conversation(conversation, true)
    message = conversation.messages.create!(account: account, inbox: conversation.inbox, sender: colleague, message_type: :outgoing,
                                            content: 'Synthetic')
    CorporateDelivery.create!(account: account, message: message, actor: colleague, assignment_version: 0, state: 'unknown')
    expect { service.conversation(conversation, false) }.to raise_error(Corporate::DispatchInProgress)
    expect(Corporate.can_read?(account, colleague, conversation)).to be(true)
    expect(CorporateSharingAudit.where(action: 'conversation_private')).to be_empty
  end

  it 'does not clear a colleague’s unread messages when another reader opens a shared chat' do
    service.conversation(conversation, true)
    3.times do
      conversation.messages.create!(account: account, inbox: conversation.inbox, sender: contact, message_type: :incoming, content: 'Synthetic')
    end
    Corporate::PersonalReads.mark(conversation, owner, at: Time.current)
    expect(Corporate::PersonalReads.count(conversation, owner)).to eq(0)
    expect(Corporate::PersonalReads.count(conversation, colleague)).to eq(3)
    counts = Corporate::ConversationTabs.new(Corporate.conversations(account, colleague), colleague, account: account).counts
    expect(counts[:shared_count]).to eq(1)
    expect(counts[:shared_unread_count]).to eq(3)
  end

  it 'requires literal booleans and rejects cross-account sharing' do
    expect { service.absence('true') }.to raise_error(ActionController::BadRequest)
    foreign_account = Account.create!(name: 'Foreign')
    foreign = chat(foreign_account, client(foreign_account))
    expect { service.conversation(foreign, true) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  def auth(user)
    { 'Authorization' => "Bearer #{user.access_token.token}" }
  end

  it 'enforces sharing permissions through HTTP and returns personal unread JSON' do
    endpoint = "/api/v1/accounts/#{account.id}/corporate/sharing/conversations/#{conversation.display_id}"
    patch endpoint, params: { shared: true }, headers: auth(colleague), as: :json
    expect(response).to have_http_status(:not_found)
    patch endpoint, params: { shared: true }, headers: auth(owner), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('shared' => true, 'can_manage' => true)
    get endpoint, headers: auth(colleague)
    expect(response.parsed_body).to include('shared' => true, 'can_manage' => false)
    get endpoint, headers: auth(technical)
    expect(response).to have_http_status(:not_found)
  end

  it 'returns independent unread JSON and shared tab counts over HTTP' do
    service.conversation(conversation, true)
    conversation.messages.create!(account: account, inbox: conversation.inbox, sender: contact, message_type: :incoming, content: 'Synthetic')
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen", headers: auth(owner)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('id' => conversation.display_id, 'unread_count' => 0)
    get "/api/v1/accounts/#{account.id}/conversations/meta", headers: auth(colleague)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('meta')).to include('shared_count' => 1, 'shared_unread_count' => 1)
    get "/api/v1/accounts/#{account.id}/conversations", params: { assignee_type: 'shared' }, headers: auth(colleague)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'payload').map { |row| row['id'] }).to eq([conversation.display_id])
  end

  it 'keeps shared chat reads and broadcasts separate from private sibling content' do
    service.conversation(conversation, true)
    allow(ActionCable.server).to receive(:broadcast)
    Corporate::BroadcastJob.perform_now(account.id, 'conversation.updated', { id: sibling.display_id })
    expect(ActionCable.server).not_to have_received(:broadcast).with(Corporate.stream(account.id, colleague.id), anything)
    Corporate::BroadcastJob.perform_now(account.id, 'conversation.updated', { id: conversation.display_id })
    expect(ActionCable.server).to have_received(:broadcast).with(Corporate.stream(account.id, colleague.id),
                                                                 hash_including(event: 'conversation.updated'))
    get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations", headers: auth(colleague)
    expect(response.parsed_body.fetch('payload').map { |row| row['id'] }).to eq([conversation.display_id])
    get "/api/v1/accounts/#{account.id}/conversations/#{sibling.display_id}/messages", headers: auth(colleague)
    expect(response.status).to be_in([401, 404])
  end

  it 'removes absence access when the employee is disabled or CRM changes the owner' do
    service.absence(true)
    Corporate::OwnershipService.new(account: account, actor: nil).sync_from_crm(contact: contact, owner_id: staff(account, 'manager').id)
    expect(Corporate.can_read?(account, colleague, conversation)).to be(false)
    owned = chat(account, client(account, owner: owner))
    expect(Corporate.can_read?(account, colleague, owned)).to be(true)
    Corporate::StaffService.new(account: account, actor: supervisor).disable(owner.id)
    expect(Corporate.can_read?(account, colleague, owned)).to be(false)
    expect(CorporateMembership.find_by!(account: account, user: owner).chats_shared_while_absent).to be(false)
  end

  it 'keeps bot or unclassified private messages out of automatic shared intake and backfill' do
    event = { channel: 'telegram', external_account_id: '10', external_user_id: '20', external_chat_id: '20', external_message_id: '30',
              event_type: 'received', direction: 'incoming', text: 'Synthetic bot', sharing_restricted: true }
    with_modified_env(CORPORATE_SHARED_INTAKE_ENABLED: 'true') do
      message = Corporate::IngestEvent.new(account: account, inbox: conversation.inbox).perform(event, [])
      expect(CustomerOwnership.find_by!(contact: message.conversation.contact)).not_to be_shared_unidentified
      expect(Corporate.can_read?(account, colleague, message)).to be(false)
      expect(Corporate::SharedIntakeBackfill.new(account).perform).to eq(0)
      Corporate::SharingService.new(account: account, actor: supervisor).conversation(message.conversation, true)
      expect(Corporate.can_read?(account, colleague, message)).to be(true)
    end
  end

  it 'authorizes shared media by conversation and revokes the same URL after closing' do
    service.conversation(conversation, true)
    [conversation, sibling].each do |target|
      message = target.messages.create!(account: account, inbox: target.inbox, message_type: :incoming, content: 'Synthetic')
      attachment = Attachment.create!(account: account, message: message, file_type: :file, meta: { scan_state: 'clean' })
      head "/api/v1/corporate_files/#{attachment.id}", headers: auth(colleague)
      expect(response.status).to eq(target == conversation ? 200 : 404)
      next unless target == conversation

      service.conversation(conversation, false)
      head "/api/v1/corporate_files/#{attachment.id}", headers: auth(colleague)
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'refreshes read and absence metadata between broadcasts on the same worker thread' do
    service.conversation(conversation, true)
    colleague
    conversation.messages.create!(account: account, inbox: conversation.inbox, message_type: :incoming, content: 'Synthetic')
    published = {}
    allow(ActionCable.server).to receive(:broadcast) { |stream, payload| published[stream] = payload }
    Corporate::BroadcastJob.perform_now(account.id, 'conversation.updated', { id: conversation.display_id })
    stream = Corporate.stream(account.id, colleague.id)
    expect(published.fetch(stream).dig(:data, :unread_count)).to eq(1)
    CorporateConversationView.create!(account: account, conversation: conversation, user: colleague, last_seen_at: Time.current)
    Corporate.membership(account, owner).update!(chats_shared_while_absent: true)
    Corporate::BroadcastJob.perform_now(account.id, 'conversation.updated', { id: conversation.display_id })
    expect(published.fetch(stream).dig(:data, :unread_count)).to eq(0)
    expect(published.fetch(stream).dig(:data, :corporate_sharing, :absence)).to be(true)
  end
end
