require 'corporate_helper'

RSpec.describe 'Independent audit reproductions', type: :request do
  let(:account) { Account.create!(name: 'Synthetic audit') }
  let(:manager) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:contact) { client(account, owner: manager) }
  let(:conversation) { chat(account, contact) }

  it 'demonstrates that uncertain delivery prevents revoking a manager' do
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Synthetic')).perform
    CorporateDelivery.find_by!(message: message).set_state!('unknown')
    expect { Corporate::StaffService.new(account: account, actor: supervisor).disable(manager.id) }.to raise_error(Corporate::DispatchInProgress)
    expect(Corporate.role(account, manager)).to eq('manager')
    expect(Corporate.can_read?(account, manager, conversation)).to be(true)
  end

  it 'demonstrates that private-note uploads are downloadable without quarantine' do
    file = Tempfile.new(['harmless-av-probe', '.txt'])
    file.write('X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*')
    file.close
    upload = Rack::Test::UploadedFile.new(file.path, 'text/plain')
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(
      content: 'Synthetic note', private: true, attachments: [upload]
    )).perform
    expect(CorporateDelivery.exists?(message: message)).to be(false)
    get "/api/v1/corporate_files/#{message.attachments.first.id}", headers: { 'Authorization' => "Bearer #{supervisor.access_token.token}" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('EICAR-STANDARD-ANTIVIRUS-TEST-FILE')
  ensure
    file&.unlink
  end

  it 'demonstrates that 50 unknown operations hide newer pending operations' do
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Synthetic')).perform
    ChannelIdentity.create!(account: account, contact: contact, channel: 'telegram', external_account_id: 'mock', external_user_id: '11')
    first = CorporateDelivery.find_by!(message: message)
    first.set_state!('unknown')
    49.times do
      m = conversation.messages.create!(account: account, inbox: conversation.inbox, sender: manager, content: 'Synthetic', message_type: :outgoing)
      CorporateDelivery.create!(account: account, message: m, actor: manager, assignment_version: 0, state: 'unknown')
    end
    last_message = conversation.messages.create!(account: account, inbox: conversation.inbox, sender: manager, content: 'New synthetic', message_type: :outgoing)
    pending = CorporateDelivery.create!(account: account, message: last_message, actor: manager, assignment_version: 0, state: 'pending')
    with_modified_env(CORPORATE_ACCOUNT_ID: account.id.to_s, CORPORATE_INBOX_ID: conversation.inbox_id.to_s, CW_SERVICE_TOKEN: 's' * 64) do
      get '/internal/corporate/outbox', headers: { 'Authorization' => "Bearer #{'s' * 64}" }
      expect(response).to have_http_status(:ok)
      returned = response.parsed_body.fetch('operations')
      expect(returned.length).to eq(50)
      expect(returned.none? { |x| x['operation_id'] == pending.operation_id }).to be(true)
    end
  end
end
