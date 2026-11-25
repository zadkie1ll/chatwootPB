require 'corporate_helper'

RSpec.describe 'Corporate delivery ledger' do
  let(:account) { Account.create!(name: 'Synthetic') }
  let(:manager) { staff(account, 'manager') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:contact) { client(account, owner: manager) }
  let(:conversation) { chat(account, contact) }

  it 'creates a pending durable operation together with the outgoing message' do
    params = ActionController::Parameters.new(content: 'Synthetic outgoing')
    message = Messages::MessageBuilder.new(manager, conversation, params).perform
    delivery = CorporateDelivery.find_by!(message: message)
    expect(delivery.state).to eq('pending')
    expect(delivery.assignment_version).to eq(CustomerOwnership.find_by!(contact: contact).lock_version)
    expect(message.reload.content_attributes['corporate_delivery']).to eq('pending')
  end

  it 'never creates a delivery operation for an internal note' do
    params = ActionController::Parameters.new(content: 'Private synthetic', private: true)
    expect { Messages::MessageBuilder.new(manager, conversation, params).perform }.not_to change(CorporateDelivery, :count)
  end

  it 'cancels pending operations on transfer and fences in-flight operations' do
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Synthetic')).perform
    delivery = CorporateDelivery.find_by!(message: message)
    service = Corporate::OwnershipService.new(account: account, actor: supervisor)
    delivery.update!(state: 'in_flight')
    expect { service.transfer(contact: contact, owner_id: nil, reason: 'Synthetic') }.to raise_error(Corporate::DispatchInProgress)
    delivery.update!(state: 'pending')
    service.transfer(contact: contact, owner_id: nil, reason: 'Synthetic')
    expect(delivery.reload.state).to eq('cancelled')
  end

  it 'deduplicates ingress and honours a deletion received before creation' do
    event = { channel: 'telegram', external_account_id: '123', external_user_id: '456', external_chat_id: '456',
              external_message_id: '789', event_type: 'received', direction: 'incoming', text: 'Synthetic' }
    service = Corporate::IngestEvent.new(account: account, inbox: conversation.inbox)
    first = service.perform(event, [])
    expect(service.perform(event, []).id).to eq(first.id)
    service.perform(event.merge(external_message_id: '999', event_type: 'deleted'), [])
    expect(service.perform(event.merge(external_message_id: '999'), [])).to be_nil
  end
end
