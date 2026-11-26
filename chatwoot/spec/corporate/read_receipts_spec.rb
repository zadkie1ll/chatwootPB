require 'corporate_helper'

RSpec.describe Corporate::ReadReceipts do
  let(:account) { Account.create!(name: 'Synthetic read receipts') }
  let(:manager) { staff(account, 'manager') }
  let(:contact) { client(account, owner: manager) }
  let(:conversation) { chat(account, contact) }
  let(:other_conversation) { chat(account, contact) }
  let(:event) do
    { channel: 'telegram', external_account_id: '10', external_user_id: '20', external_chat_id: '20',
      external_message_id: '101', direction: 'outgoing', event_type: 'read', revision: '', text: '' }
  end
  let(:service) { described_class.new(account: account, inbox: conversation.inbox) }

  before do
    conversation.contact_inbox.update!(source_id: '20')
    ChannelIdentity.create!(account: account, contact: contact, channel: 'telegram', external_account_id: '10', external_user_id: '20')
  end

  def outgoing(chat, source)
    chat.messages.create!(account: account, inbox: chat.inbox, sender: manager, message_type: :outgoing, content: 'Synthetic', source_id: source)
  end

  it 'marks only outgoing messages through the confirmed Telegram watermark in this inbox' do
    older = outgoing(conversation, '100')
    newer = outgoing(conversation, '102')
    foreign = outgoing(other_conversation, '100')
    incoming = conversation.messages.create!(account: account, inbox: conversation.inbox, sender: contact, message_type: :incoming,
                                             content: 'Synthetic', source_id: '99')
    service.perform(event)
    expect(older.reload).to be_read
    expect(newer.reload).to be_sent
    expect(foreign.reload).to be_sent
    expect(incoming.reload).to be_sent
  end

  it 'retains a read receipt that arrives before the send acknowledgement and never downgrades it' do
    message = outgoing(conversation, nil)
    service.perform(event)
    delivery = CorporateDelivery.create!(account: account, actor: manager, message: message, state: 'in_flight', assignment_version: 1)
    delivery.set_state!('sent', external_id: '100')
    expect(message.reload).to be_read
    delivery.set_state!('sent', external_id: '100')
    expect(message.reload).to be_read
  end

  it 'uses exact message IDs for MAX rather than assuming its IDs are sequential' do
    ChannelIdentity.create!(account: account, contact: contact, channel: 'max', external_account_id: '10', external_user_id: '20')
    selected = outgoing(conversation, '101')
    other = outgoing(conversation, '100')
    service.perform(event.merge(channel: 'max', external_chat_id: '30'))
    expect(selected.reload).to be_read
    expect(other.reload).to be_sent
  end

  it 'ignores unknown external identities without creating clients or conversations' do
    expect { service.perform(event.merge(external_user_id: '999')) }.not_to change(Contact, :count)
    expect(conversation.reload.additional_attributes['corporate_read_through']).to be_nil
  end
end
