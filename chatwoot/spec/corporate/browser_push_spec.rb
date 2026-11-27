require 'corporate_helper'

RSpec.describe 'Corporate browser push', type: :request do
  let(:account) { Account.create!(name: 'Synthetic push') }
  let(:manager) { staff(account, 'manager') }
  let(:other) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:contact) { client(account, owner: manager) }
  let(:conversation) { chat(account, contact) }
  let(:headers) { manager.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/corporate/browser_push" }
  let(:endpoint) { 'https://fcm.googleapis.com/fcm/send/synthetic-token' }
  let(:payload) { { endpoint: endpoint, keys: { p256dh: 'B' * 87, auth: 'C' * 22 } } }

  around do |example|
    with_modified_env(CORPORATE_BROWSER_PUSH_ENABLED: 'true', CORPORATE_PUSH_ORIGINS: 'http://www.example.com',
                      FRONTEND_URL: 'https://mess.example.invalid') { example.run }
  end

  def register
    post path, params: { subscription: payload }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    NotificationSubscription.find_by!(identifier: endpoint)
  end

  def subscription_for(user, suffix)
    user.update!(tokens: { 'synthetic' => { 'expiry' => 1.day.from_now.to_i } })
    NotificationSubscription.create!(user: user, subscription_type: :browser_push, identifier: "#{endpoint}-#{suffix}",
                                     subscription_attributes: { endpoint: "#{endpoint}-#{suffix}", p256dh: WebPush.generate_key.public_key,
                                                                auth: SecureRandom.urlsafe_base64(16),
                                                                corporate_account_id: account.id.to_s, origin: 'http://www.example.com',
                                                                client: 'synthetic' })
  end

  it 'registers only this signed-in browser and does not expose subscription secrets in status' do
    register
    post "#{path}/status", params: { endpoint: endpoint }, headers: headers, as: :json
    expect(response.parsed_body).to include('configured' => true, 'connected' => true)
    expect(response.body).not_to include('synthetic-token', 'p256dh', 'auth')
    delete path, params: { endpoint: endpoint }, headers: headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(NotificationSubscription.exists?(identifier: endpoint)).to be(false)
  end

  it 'rejects internal URLs and lookalike provider hosts before making any request' do
    %w[https://127.0.0.1/push https://fcm.googleapis.com.evil.invalid/send http://fcm.googleapis.com/send
       https://fcm.googleapis.com:8443/send].each do |url|
      post path, params: { subscription: payload.merge(endpoint: url) }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(NotificationSubscription.count).to eq(0)
  end

  it 'does not expose or test another user subscription' do
    register
    post "#{path}/test", params: { endpoint: endpoint }, headers: other.create_new_auth_token, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'forbids technical administrators and disabled staff' do
    technical = staff(account, 'technical_admin')
    post "#{path}/status", headers: technical.create_new_auth_token, as: :json
    expect(response).to have_http_status(:not_found)
    CorporateMembership.find_by!(user: manager).update!(active: false)
    post "#{path}/status", headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'requires an authentic worker receipt and user confirmation before reporting a verified test' do
    register
    allow(WebPush).to receive(:payload_send)
    post "#{path}/test", params: { endpoint: endpoint }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['confirmed_at']).to be_nil
    expect(WebPush).to have_received(:payload_send) do |**args|
      data = JSON.parse(args.fetch(:message))
      post '/api/v1/corporate_push_receipts', params: { token: data.fetch('receipt_token') }, as: :json
      expect(response).to have_http_status(:no_content)
    end
    post "#{path}/confirm", params: { endpoint: endpoint }, headers: headers, as: :json
    expect(response.parsed_body['test_received_at']).to be_present
    expect(response.parsed_body['confirmed_at']).to be_present
  end

  it 'does not allow an unreceived test to be confirmed or a forged receipt' do
    register
    post "#{path}/confirm", params: { endpoint: endpoint }, headers: headers, as: :json
    expect(response.parsed_body['error_code']).to eq('test_not_received')
    post '/api/v1/corporate_push_receipts', params: { token: 'forged' }, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'sends only generic content to current readers and excludes technical, disabled and unrelated managers' do
    [manager, other, supervisor, staff(account, 'technical_admin')].each_with_index { |user, i| subscription_for(user, i) }
    message = conversation.messages.create!(account: account, inbox: conversation.inbox, message_type: :incoming, content: 'Private synthetic text')
    allow(WebPush).to receive(:payload_send)
    Corporate::PushMessageJob.perform_now(message.id)
    expect(WebPush).to have_received(:payload_send).twice
    expect(WebPush).to have_received(:payload_send).with(hash_including(message: satisfy { |data| data.exclude?('Private synthetic') })).twice
    CustomerOwnership.find_by!(contact: contact).update!(owner: other)
    CorporateMembership.find_by!(user: supervisor).update!(active: false)
    allow(WebPush).to receive(:payload_send)
    Corporate::PushMessageJob.perform_now(message.id)
    expect(WebPush).to have_received(:payload_send).with(hash_including(endpoint: "#{endpoint}-1"))
    expect(WebPush).to have_received(:payload_send).with(hash_including(endpoint: "#{endpoint}-0")).once
    expect(WebPush).to have_received(:payload_send).with(hash_including(endpoint: "#{endpoint}-2")).once
  end

  it 'does not send after logout or when notifications are disabled' do
    subscription_for(manager, 'logout')
    manager.update!(tokens: {})
    message = conversation.messages.create!(account: account, inbox: conversation.inbox, message_type: :incoming, content: 'Synthetic')
    allow(WebPush).to receive(:payload_send)
    Corporate::PushMessageJob.perform_now(message.id)
    expect(WebPush).not_to have_received(:payload_send)
    with_modified_env(CORPORATE_BROWSER_PUSH_ENABLED: 'false') { Corporate::PushMessageJob.perform_now(message.id) }
    expect(WebPush).not_to have_received(:payload_send)
  end

  it 'uses the real Web Push encryption and removes a subscription rejected with HTTP 410' do
    record = subscription_for(manager, 'wire')
    target = record.subscription_attributes.fetch('endpoint')
    stub_request(:post, target).to_return(status: 201, body: '')
    Corporate::BrowserPushSender.send!(record, title: 'Synthetic')
    expect(WebMock).to have_requested(:post, target)
    stub_request(:post, target).to_return(status: 410, body: '')
    expect { Corporate::BrowserPushSender.send!(record, title: 'Synthetic') }
      .to raise_error(Corporate::BrowserPush::Error, 'subscription_expired')
    expect(NotificationSubscription.exists?(id: record.id)).to be(false)
  end

  it 'stops notifying a colleague after shared access is revoked' do
    subscription_for(other, 'shared')
    share = CorporateConversationShare.create!(account: account, conversation: conversation, shared_by: manager)
    message = conversation.messages.create!(account: account, inbox: conversation.inbox, message_type: :incoming, content: 'Synthetic')
    allow(WebPush).to receive(:payload_send)
    Corporate::PushMessageJob.perform_now(message.id)
    expect(WebPush).to have_received(:payload_send).once
    share.destroy!
    Corporate::PushMessageJob.perform_now(message.id)
    expect(WebPush).to have_received(:payload_send).once
  end

  it 'does not let one failed browser prevent another visible recipient from being notified' do
    record = subscription_for(manager, 'failed')
    subscription_for(supervisor, 'working')
    message = conversation.messages.create!(account: account, inbox: conversation.inbox, message_type: :incoming, content: 'Synthetic')
    allow(WebPush).to receive(:payload_send)
    allow(WebPush).to receive(:payload_send).with(hash_including(endpoint: record.identifier)).and_raise(Errno::ECONNRESET)
    Corporate::PushMessageJob.perform_now(message.id)
    expect(WebPush).to have_received(:payload_send).twice
    expect(record.reload.subscription_attributes['last_error']).to eq('push_unavailable')
  end
end
