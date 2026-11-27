require 'corporate_helper'

RSpec.describe 'Corporate manager administration', type: :request do
  let(:account) { Account.create!(name: 'Synthetic staff admin') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:manager) { staff(account, 'manager') }
  let(:headers) { { 'Authorization' => "Bearer #{supervisor.access_token.token}" } }
  let(:base) { "/api/v1/accounts/#{account.id}/corporate/staff" }

  it 'lists all manager states with accurate workload and safe public fields' do
    member = CorporateMembership.find_by!(user: manager)
    member.update!(chats_shared_while_absent: true)
    disabled = staff(account, 'manager')
    CorporateMembership.find_by!(user: disabled).update!(active: false)
    contact = client(account, owner: manager)
    2.times { chat(account, contact) }
    get "#{base}/directory", headers: headers
    data = response.parsed_body
    expect(response).to have_http_status(:ok)
    expect(data.dig('meta', 'summary')).to include('total' => 2, 'active' => 1, 'disabled' => 1)
    row = data.fetch('payload').find { |record| record['id'] == manager.id }
    expect(row).to include('clients_count' => 1, 'conversations_count' => 2, 'absence' => true, 'account_id' => account.id)
    expect(response.body).not_to include('tokens', 'pubsub_token', 'encrypted_password', 'Private synthetic client')
  end

  it 'searches and filters before pagination and rejects malformed filters' do
    manager.update!(name: 'Unique synthetic name')
    other = staff(account, 'manager')
    CorporateMembership.find_by!(user: other).update!(active: false)
    get "#{base}/directory", params: { q: 'UNIQUE', status: 'active' }, headers: headers
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([manager.id])
    get "#{base}/directory", params: { page: '-1' }, headers: headers
    expect(response).to have_http_status(:bad_request)
    get "#{base}/directory", params: { status: 'administrator' }, headers: headers
    expect(response).to have_http_status(:bad_request)
    get "#{base}/directory", params: { q: ['invalid'] }, headers: headers
    expect(response).to have_http_status(:bad_request)
  end

  it 'denies management and directory access to managers, technical staff and other accounts' do
    technical = staff(account, 'technical_admin')
    [manager, technical].each do |user|
      get "#{base}/directory", headers: { 'Authorization' => "Bearer #{user.access_token.token}" }
      expect(response).to have_http_status(:not_found)
      patch "#{base}/#{manager.id}", params: { name: 'Forbidden' }, headers: { 'Authorization' => "Bearer #{user.access_token.token}" }
      expect(response).to have_http_status(:not_found)
    end
    foreign_account = Account.create!(name: 'Other synthetic organization')
    foreign = staff(foreign_account, 'manager')
    patch "#{base}/#{foreign.id}", params: { name: 'Forbidden' }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'creates a trusted Bitrix manager and mapping atomically without trusting caller identity fields' do
    directory = { 'employees' => [{ 'id' => '901', 'name' => 'Synthetic CRM employee', 'email' => 'crm-staff@example.invalid' }] }
    crm = instance_double(Corporate::CrmClient, call: directory)
    allow(Corporate::CrmClient).to receive(:new).and_return(crm)
    with_modified_env(BITRIX_ENABLED: 'true', CORPORATE_ACCOUNT_ID: account.id.to_s) do
      post base, params: { name: 'Caller supplied', email: 'forged@example.invalid', password: 'SyntheticPassword12!', bitrix_user_id: '901' },
                 headers: headers
      expect(response).to have_http_status(:created)
      user = User.find(response.parsed_body.fetch('id'))
      expect(user).to have_attributes(name: 'Synthetic CRM employee', email: 'crm-staff@example.invalid')
      expect(CorporateCrmEmployee.find_by!(account: account, user: user).external_user_id).to eq('901')
      post base, params: { password: 'SyntheticPassword12!', bitrix_user_id: '901' }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(CorporateMembership.where(account: account, role: 'manager').count).to eq(1)
    end
  end

  it 'revokes existing sessions when the supervisor changes credentials without changing the employee ID' do
    old_headers = manager.create_new_auth_token
    old_token = manager.access_token.token
    patch "#{base}/#{manager.id}", params: { email: 'changed@example.invalid', password: 'UpdatedPassword12!' }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(manager.id)
    expect(manager.reload).to be_valid_password('UpdatedPassword12!')
    expect(manager.access_token.reload.token).not_to eq(old_token)
    get "/api/v1/accounts/#{account.id}/corporate/access", headers: old_headers
    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses a short password and preserves the previous profile' do
    original_email = manager.email
    patch "#{base}/#{manager.id}", params: { email: 'changed@example.invalid', password: 'Weak1!' }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(manager.reload.email).to eq(original_email)
  end

  it 'restores a disabled manager only after client cleanup and never restores previous ownership' do
    contact = client(account, owner: manager)
    chat(account, contact)
    service = Corporate::StaffService.new(account: account, actor: supervisor)
    service.disable(manager.id)
    post "#{base}/#{manager.id}/enable", headers: headers
    expect(response).to have_http_status(:conflict)
    Corporate::DisabledStaffCleanupJob.perform_now(account.id, manager.id, supervisor.id)
    post "#{base}/#{manager.id}/enable", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(Corporate.role(account, manager)).to eq('manager')
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to be_nil
  end

  it 'paginates the full directory without the legacy two-hundred-row cutoff' do
    26.times { staff(account, 'manager') }
    get "#{base}/directory", headers: headers
    expect(response.parsed_body.fetch('payload').size).to eq(25)
    expect(response.parsed_body.dig('meta', 'total')).to eq(26)
    get "#{base}/directory", params: { page: 2 }, headers: headers
    expect(response.parsed_body.fetch('payload').size).to eq(1)
  end

  it 'does not release a client that was transferred to another employee after the cleanup batch was selected' do
    other = staff(account, 'manager')
    contact = client(account, owner: manager)
    ownership = CustomerOwnership.find_by!(contact: contact)
    CorporateMembership.find_by!(user: manager).update!(active: false)
    batch = instance_double(ActiveRecord::Relation)
    allow(CustomerOwnership).to receive(:where).and_call_original
    allow(CustomerOwnership).to receive(:where).with(account: account, owner_id: manager.id).and_return(batch)
    allow(batch).to receive(:find_each) do |&block|
      ownership.update!(owner: other)
      block.call(ownership)
    end
    Corporate::DisabledStaffCleanupJob.perform_now(account.id, manager.id, supervisor.id)
    expect(ownership.reload.owner_id).to eq(other.id)
  end

  it 'rolls back profile changes if an external mapping is already in use' do
    other = staff(account, 'manager')
    CorporateCrmEmployee.create!(account: account, user: other, external_user_id: '901')
    directory = { 'employees' => [{ 'id' => '901', 'name' => 'Synthetic CRM employee', 'email' => 'crm-staff@example.invalid' }] }
    crm = instance_double(Corporate::CrmClient, call: directory)
    allow(Corporate::CrmClient).to receive(:new).and_return(crm)
    original = manager.name
    with_modified_env(BITRIX_ENABLED: 'true', CORPORATE_ACCOUNT_ID: account.id.to_s) do
      patch "#{base}/#{manager.id}", params: { name: 'Must roll back', bitrix_user_id: '901' }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(manager.reload.name).to eq(original)
      expect(CorporateCrmEmployee.find_by!(account: account, external_user_id: '901').user_id).to eq(other.id)
    end
  end
end
