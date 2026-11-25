require 'corporate_helper'

RSpec.describe RoomChannel, type: :channel do
  it 'subscribes only to the authenticated corporate stream' do
    account = Account.create!(name: 'Synthetic account')
    manager = staff(account, 'manager')
    stub_connection
    subscribe(pubsub_token: manager.pubsub_token, user_id: manager.id, account_id: account.id)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(Corporate.stream(account.id, manager.id))
    expect(subscription).not_to have_stream_from("account_#{account.id}")
    expect(subscription).not_to have_stream_from(manager.pubsub_token)
  end

  it 'rejects users without an active business membership' do
    account = Account.create!(name: 'Synthetic account')
    manager = staff(account, 'manager')
    CorporateMembership.find_by!(account: account, user: manager).update!(active: false)
    stub_connection
    subscribe(pubsub_token: manager.pubsub_token, user_id: manager.id, account_id: account.id)
    expect(subscription).to be_rejected
  end
end
