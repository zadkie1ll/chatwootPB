require 'corporate_helper'

RSpec.describe 'Corporate conversation summary', type: :request do
  let(:account) { Account.create!(name: 'Summary synthetic account') }
  let(:manager) { staff(account, 'manager') }
  let(:other) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:technical) { staff(account, 'technical_admin') }
  let(:contact) { client(account, owner: manager) }
  let(:conversation) { chat(account, contact) }
  let(:path) { "/api/v1/accounts/#{account.id}/corporate/conversations/#{conversation.display_id}/summary" }
  let(:answer) { { status: 'completed', output: [{ content: [{ type: 'output_text', text: 'Synthetic safe summary' }] }] } }

  def auth(user)
    { 'Authorization' => "Bearer #{user.access_token.token}" }
  end

  def message(content, private: false)
    conversation.messages.create!(account: account, inbox: conversation.inbox, sender: contact,
                                  content: content, private: private, message_type: :incoming)
  end

  before do
    Rails.cache.clear
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with('/run/secrets/openai/api-key').and_return('synthetic-key')
  end

  it 'allows the owner and supervisor and omits private notes from the provider request' do
    message('Public synthetic appointment')
    message('Private synthetic internal note', private: true)
    request = stub_request(:post, Corporate::ConversationSummary::ENDPOINT).with do |r|
      data = JSON.parse(r.body)
      data['store'] == false && data['input'].include?('Public synthetic appointment') &&
        data['input'].exclude?('Private synthetic internal note') && data['model'] == 'gpt-6-luna'
    end.to_return(status: 200, body: answer.to_json)
    [manager, supervisor].each do |user|
      post path, headers: auth(user)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['summary']).to eq('Synthetic safe summary')
      expect(response.body).not_to include('synthetic-key')
    end
    expect(request).to have_been_requested.twice
  end

  it 'denies other managers and technical administrators before contacting OpenAI' do
    message('Synthetic client content')
    [other, technical].each do |user|
      post path, headers: auth(user)
      expect(response).to have_http_status(:not_found)
    end
    expect(WebMock).not_to have_requested(:post, Corporate::ConversationSummary::ENDPOINT)
  end

  it 'rechecks ownership after generation and withholds the result from the former owner' do
    message('Synthetic public content')
    stub_request(:post, Corporate::ConversationSummary::ENDPOINT).to_return do
      CustomerOwnership.find_by!(contact: contact).update!(owner: other)
      { status: 200, body: answer.to_json }
    end
    post path, headers: auth(manager)
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include('Synthetic safe summary')
  end

  it 'returns a visible quota failure and never includes provider error details' do
    message('Synthetic public content')
    stub_request(:post, Corporate::ConversationSummary::ENDPOINT).to_return(status: 429, body: '{"error":"sensitive upstream details"}')
    post path, headers: auth(manager)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include('sensitive upstream details')
  end

  it 'bounds the transcript and marks a partial summary' do
    message('x' * 40_000)
    request = stub_request(:post, Corporate::ConversationSummary::ENDPOINT).with do |r|
      JSON.parse(r.body)['input'].length <= Corporate::ConversationSummary::CHARACTER_LIMIT
    end.to_return(status: 200, body: answer.to_json)
    post path, headers: auth(manager)
    expect(response.parsed_body['truncated']).to be(true)
    expect(request).to have_been_requested.once
  end

  it 'does not send empty conversations to the provider' do
    post path, headers: auth(manager)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(WebMock).not_to have_requested(:post, Corporate::ConversationSummary::ENDPOINT)
  end
end
