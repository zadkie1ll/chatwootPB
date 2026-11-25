require 'corporate_helper'

RSpec.describe 'Corporate MAX pilot connection', type: :request do
  let(:account) { Account.create!(name: 'MAX synthetic account') }
  let(:manager) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:technical) { staff(account, 'technical_admin') }
  let(:path) { "/api/v1/accounts/#{account.id}/corporate/max_channel" }

  around do |example|
    with_modified_env(CORPORATE_ACCOUNT_ID: account.id.to_s, INTEGRATION_URL: 'http://integration-web:8090',
                      INTEGRATION_API_TOKEN: 'a' * 64) { example.run }
  end

  def auth(user)
    { 'Authorization' => "Bearer #{user.access_token.token}" }
  end

  it 'withholds MAX QR and password controls from managers and supervisors' do
    [manager, supervisor].each do |user|
      get path, headers: auth(user)
      expect(response).to have_http_status(:not_found)
      post "#{path}/connect", params: { step: 'start' }, headers: auth(user)
      expect(response).to have_http_status(:not_found)
    end
    expect(WebMock).not_to have_requested(:get, 'http://integration-web:8090/max-channel/status/')
  end

  it 'exposes the private non-cacheable QR only to the technical administrator' do
    stub_request(:get, 'http://integration-web:8090/max-channel/status/')
      .with(headers: { 'Authorization' => "Bearer #{'a' * 64}" })
      .to_return(status: 200, body: { status: 'qr_required', qr_image: 'data:image/svg+xml;base64,synthetic', poc_only: true }.to_json)
    get path, headers: auth(technical)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['status']).to eq('qr_required')
    expect(response.headers['Cache-Control']).to include('no-store')
  end

  it 'passes a 2FA password in a POST body without reflecting it in the response' do
    request = stub_request(:post, 'http://integration-web:8090/max-channel/password/')
              .with(body: { password: 'SyntheticMaxPassword', attempt_id: 'synthetic-attempt' }.to_json)
              .to_return(status: 200, body: { status: 'authenticating' }.to_json)
    post "#{path}/connect", params: { step: 'password', password: 'SyntheticMaxPassword', attempt_id: 'synthetic-attempt' }, headers: auth(technical)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('SyntheticMaxPassword')
    expect(request).to have_been_requested.once
  end

  it 'does not expose the single server session through another account' do
    foreign = Account.create!(name: 'Foreign MAX synthetic account')
    user = staff(foreign, 'technical_admin')
    get "/api/v1/accounts/#{foreign.id}/corporate/max_channel", headers: auth(user)
    expect(response).to have_http_status(:not_found)
  end
end
