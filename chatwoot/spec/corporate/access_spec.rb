require 'corporate_helper'

RSpec.describe 'Corporate ownership and HTTP access', type: :request do
  let(:account) { Account.create!(name: 'Synthetic account') }
  let(:manager_a) { staff(account, 'manager') }
  let(:manager_b) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:technical) { staff(account, 'technical_admin') }
  let(:contact) { client(account, owner: manager_a) }
  let(:conversation) { chat(account, contact) }

  def auth(user)
    { 'Authorization' => "Bearer #{user.access_token.token}" }
  end

  it 'denies Telegram authorization to managers and supervisors' do
    [manager_a, supervisor].each do |user|
      get "/api/v1/accounts/#{account.id}/corporate/channel", headers: auth(user)
      expect(response).to have_http_status(:not_found)
      post "/api/v1/accounts/#{account.id}/corporate/channel/connect", params: { step: 'start' }, headers: auth(user)
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'prevents technical settings from redirecting customer webhooks' do
    patch "/api/v1/accounts/#{account.id}/inboxes/#{conversation.inbox_id}",
          params: { channel: { webhook_url: 'https://example.invalid/collector' } }, headers: auth(technical)
    expect(response).to have_http_status(:not_found)
    expect(conversation.inbox.channel.reload.webhook_url).to be_nil
  end

  it 'allows only the supervisor to create and list managers' do
    [manager_a, technical].each do |user|
      get "/api/v1/accounts/#{account.id}/corporate/staff", headers: auth(user)
      expect(response).to have_http_status(:not_found)
    end
    post "/api/v1/accounts/#{account.id}/corporate/staff", params: {
      name: 'Synthetic new employee', email: 'request-manager@example.invalid', password: 'SyntheticPassword12!'
    }, headers: auth(supervisor)
    expect(response).to have_http_status(:created)
    expect(response.body).not_to include('SyntheticPassword12!')
    get "/api/v1/accounts/#{account.id}/corporate/staff", headers: auth(supervisor)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('request-manager@example.invalid')
  end

  it 'permits the owner and supervisor, denies another manager and technical administrator' do
    [manager_a, supervisor].each do |user|
      get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}", headers: auth(user)
      expect(response).to have_http_status(:ok)
    end
    [manager_b, technical].each do |user|
      get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}", headers: auth(user)
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(contact.name)
    end
  end

  it 'does not grant ownership through inbox or team membership or administrator role' do
    InboxMember.create!(inbox: conversation.inbox, user: manager_b)
    context = { user: manager_b, account: account, account_user: account.account_users.find_by!(user: manager_b) }
    expect(ConversationPolicy.new(context, conversation).show?).to be(false)
    context = { user: technical, account: account, account_user: account.account_users.find_by!(user: technical) }
    expect(ConversationPolicy.new(context, conversation).show?).to be(false)
  end

  it 'denies the unassigned queue to managers' do
    unassigned = client(account)
    expect(Corporate.contacts(account, manager_a)).not_to include(unassigned)
    expect(Corporate.contacts(account, supervisor)).to include(unassigned)
  end

  it 'transfers all conversations and writes one audit entry without releasing on close' do
    conversation
    service = Corporate::OwnershipService.new(account: account, actor: supervisor)
    expect { service.transfer(contact: contact, owner_id: manager_b.id, reason: 'Synthetic transfer') }.to change(AssignmentAudit, :count).by(1)
    expect(conversation.reload.assignee_id).to eq(manager_b.id)
    expect(Corporate.can_read?(account, manager_a, conversation)).to be(false)
    expect(Corporate.can_read?(account, manager_b, conversation)).to be(true)
    conversation.update!(status: :resolved)
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(manager_b.id)
  end

  it 'denies manager transfer and cross-account owner assignment' do
    expect do
      Corporate::OwnershipService.new(account: account, actor: manager_a).transfer(contact: contact, owner_id: manager_b.id, reason: 'Forbidden')
    end.to raise_error(Pundit::NotAuthorizedError)
    other = Account.create!(name: 'Other account')
    outsider = staff(other, 'manager')
    expect do
      Corporate::OwnershipService.new(account: account, actor: supervisor).transfer(contact: contact, owner_id: outsider.id, reason: 'Forbidden')
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'rechecks queued broadcast recipients against the current owner' do
    message = Message.create!(account: account, inbox: conversation.inbox, conversation: conversation, message_type: :incoming, content: 'Synthetic')
    supervisor
    Corporate::OwnershipService.new(account: account, actor: supervisor).transfer(contact: contact, owner_id: manager_b.id,
                                                                                  reason: 'Transfer before dispatch')
    allow(ActionCable.server).to receive(:broadcast)
    Corporate::BroadcastJob.new.perform(account.id, 'message.created', { id: message.id })
    expect(ActionCable.server).to have_received(:broadcast).with(Corporate.stream(account.id, manager_b.id), anything)
    expect(ActionCable.server).not_to have_received(:broadcast).with(Corporate.stream(account.id, manager_a.id), anything)
  end

  it 'denies a previously valid file session after token revocation' do
    token = manager_a.access_token.token
    manager_a.access_token.regenerate_token
    expect(AccessToken.find_by(token: token)).to be_nil
    get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}", headers: { 'Authorization' => "Bearer #{token}" }
    expect(response).to have_http_status(:unauthorized)
  end
end
