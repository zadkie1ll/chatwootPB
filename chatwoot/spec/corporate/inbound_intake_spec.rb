require 'corporate_helper'

RSpec.describe Corporate::InboundIntake do
  let(:account) { Account.create!(name: 'Synthetic inbound routing') }
  let(:manager) { staff(account, 'manager') }
  let(:colleague) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:inbox) { chat(account, client(account)).inbox }
  let(:service) { Corporate::IngestEvent.new(account: account, inbox: inbox) }
  let(:event) do
    { channel: 'max', external_account_id: '10', external_user_id: '20', external_chat_id: '30', external_message_id: '100',
      direction: 'outgoing', event_type: 'received', text: 'Synthetic official client', origin: 'official_client' }
  end
  let(:crm) { instance_double(Corporate::CrmClient) }

  around do |example|
    with_modified_env(BITRIX_ENABLED: 'true', MAX_CRM_ENABLED: 'true', CORPORATE_SHARED_INTAKE_ENABLED: 'true') { example.run }
  end

  before do
    allow(Corporate::CrmClient).to receive(:new).and_return(crm)
    allow(crm).to receive(:call).with('resolve', anything).and_return('found' => false)
  end

  def incoming(original = event)
    service.perform(original.merge(external_message_id: '101', direction: 'incoming', origin: 'external'), [])
  end

  def ownership(message)
    CustomerOwnership.find_by!(account: account, contact: message.conversation.contact)
  end

  it 'publishes the first hidden-phone reply to a chat originally created by the official MAX client' do
    outbound = service.perform(event, [])
    expect(ownership(outbound)).not_to be_shared_unidentified
    reply = incoming
    expect(reply.conversation_id).to eq(outbound.conversation_id)
    expect(ownership(reply)).to be_shared_unidentified
    expect(Corporate.can_read?(account, manager, reply)).to be(true)
    expect(reply.conversation.reload.assignee_id).to be_nil
  end

  it 'preserves an existing manager and does not expose their reply to colleagues' do
    outbound = service.perform(event, [])
    Corporate::OwnershipService.new(account: account, actor: supervisor).transfer(contact: outbound.conversation.contact,
                                                                                  owner_id: manager.id, reason: 'Synthetic assignment')
    reply = incoming
    expect(reply.conversation.reload.assignee_id).to eq(manager.id)
    expect(Corporate.can_read?(account, colleague, reply)).to be(false)
  end

  it 'does not reopen a previously assigned private contact that was explicitly released' do
    outbound = service.perform(event, [])
    assignment = Corporate::OwnershipService.new(account: account, actor: supervisor)
    assignment.transfer(contact: outbound.conversation.contact, owner_id: manager.id, reason: 'Synthetic assignment')
    assignment.transfer(contact: outbound.conversation.contact, owner_id: nil, reason: 'Synthetic release')
    reply = incoming
    expect(ownership(reply)).not_to be_shared_unidentified
    expect(Corporate.can_read?(account, colleague, reply)).to be(false)
  end

  it 'keeps restricted bot messages out of automatic shared intake' do
    restricted = event.merge(sharing_restricted: true)
    service.perform(restricted, [])
    reply = incoming(restricted)
    expect(ownership(reply)).not_to be_shared_unidentified
  end

  it 'queues known-phone replies after the original outgoing lookup and opens unmatched incoming chats' do
    known = event.merge(phone: '+79990000000')
    outbound = service.perform(known, [])
    Corporate::CrmInboundLookupJob.perform_now(account.id, outbound.conversation_id)
    expect(ownership(outbound)).not_to be_shared_unidentified
    allow(Corporate::CrmInboundLookupJob).to receive(:perform_later)
    reply = incoming(known)
    expect(Corporate::CrmInboundLookupJob).to have_received(:perform_later).with(account.id, reply.conversation_id)
    Corporate::CrmInboundLookupJob.perform_now(account.id, reply.conversation_id)
    expect(ownership(reply)).to be_shared_unidentified
  end

  it 'assigns a known-phone incoming lead to the mapped Bitrix manager without changing the CRM owner' do
    CorporateCrmEmployee.create!(account: account, user: manager, external_user_id: '22')
    allow(crm).to receive(:call).and_return('found' => true, 'deal_id' => '502', 'entity_type' => 'lead',
                                            'assigned_user_id' => '22', 'title' => 'Synthetic lead',
                                            'deal_url' => 'https://crm.example.test/crm/lead/details/502/')
    service.perform(event.merge(phone: '+79990000000'), [])
    reply = incoming(event.merge(phone: '+79990000000'))
    Corporate::CrmInboundLookupJob.perform_now(account.id, reply.conversation_id)
    expect(reply.conversation.reload.assignee_id).to eq(manager.id)
    expect(Corporate.can_read?(account, colleague, reply)).to be(false)
    link = CorporateCrmLink.find_by!(account: account, contact: reply.conversation.contact)
    expect(link.entity_type).to eq('lead')
    expect(link.sync_payload).not_to have_key('assigned_user_id')
  end

  it 'can retry a prior not-found link when a lead becomes available later' do
    CorporateCrmEmployee.create!(account: account, user: manager, external_user_id: '22')
    reply = incoming(event.merge(phone: '+79990000000'))
    link = CorporateCrmLink.create!(account: account, contact: reply.conversation.contact, conversation: reply.conversation,
                                    actor: supervisor, sync_state: 'not_found', operation_id: SecureRandom.uuid)
    allow(crm).to receive(:call).and_return('found' => true, 'deal_id' => '502', 'assigned_user_id' => '22', 'title' => 'Synthetic',
                                            'deal_url' => 'https://crm.example.test/crm/deal/details/502/')
    Corporate::CrmInboundLookupJob.perform_now(account.id, reply.conversation_id)
    expect(link.reload.external_deal_id).to eq('502')
    expect(link.sync_state).to eq('pending')
    expect(ownership(reply).owner_id).to eq(manager.id)
  end

  it 'shows an unassigned incoming when the CRM owner is not mapped to an active manager' do
    reply = incoming(event.merge(phone: '+79990000000'))
    allow(crm).to receive(:call).and_return('found' => true, 'deal_id' => '502', 'assigned_user_id' => '999')
    Corporate::CrmInboundLookupJob.perform_now(account.id, reply.conversation_id)
    expect(ownership(reply)).to be_shared_unidentified
    expect(reply.conversation.reload.assignee_id).to be_nil
  end
end
