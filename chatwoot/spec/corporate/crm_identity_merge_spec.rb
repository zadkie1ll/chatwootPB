require 'corporate_helper'

RSpec.describe Corporate::CrmIdentityMerge do
  let(:account) { Account.create!(name: 'Synthetic MAX binding') }
  let(:manager) { staff(account, 'manager') }
  let(:other) { staff(account, 'manager') }
  let(:target) { client(account, owner: manager) }
  let(:source) { client(account) }
  let(:telegram) { chat(account, target) }
  let(:max_chat) do
    conversation = chat(account, source)
    conversation.update!(additional_attributes: { corporate_channel: 'max' })
    conversation
  end
  let(:result) { { 'found' => true, 'deal_id' => '901', 'entity_type' => 'deal' } }

  before do
    CustomerOwnership.find_by!(contact: source).update!(shared_unidentified: true)
    ChannelIdentity.create!(account: account, contact: target, channel: 'telegram', external_account_id: 'tg', external_user_id: '44')
    ChannelIdentity.create!(account: account, contact: source, channel: 'max', external_account_id: '10', external_user_id: '20')
    CorporateCrmLink.create!(account: account, contact: target, conversation: telegram, actor: manager, sync_state: 'applied',
                             external_deal_id: '901', entity_type: 'deal', operation_id: SecureRandom.uuid)
  end

  it 'binds a shared anonymous MAX chat to an existing readable Telegram customer and revokes the pool' do
    with_modified_env(CORPORATE_SHARED_INTAKE_ENABLED: 'true') do
      expect(Corporate.can_read?(account, other, max_chat)).to be(true)
      account.with_lock { described_class.new(account: account, actor: manager).perform(max_chat, result) }
      expect(max_chat.reload.contact_id).to eq(target.id)
      expect(ChannelIdentity.find_by!(channel: 'max', external_account_id: '10').contact_id).to eq(target.id)
      expect(Corporate.can_read?(account, manager, max_chat)).to be(true)
      expect(Corporate.can_read?(account, other, max_chat)).to be(false)
      expect(AssignmentAudit.find_by!(contact: source).reason).to eq("channel_identity_merged_into_#{target.id}")
      expect(CorporateCrmLink.count).to eq(1)
    end
  end

  it 'does not expose an existing customer owned by another manager' do
    conversation = max_chat
    with_modified_env(CORPORATE_SHARED_INTAKE_ENABLED: 'true') do
      expect { account.with_lock { described_class.new(account: account, actor: other).perform(conversation, result) } }
        .to raise_error(ActiveRecord::RecordNotFound)
      expect(max_chat.reload.contact_id).to eq(source.id)
    end
  end

  it 'waits for pending sends before moving the source contact' do
    with_modified_env(CORPORATE_SHARED_INTAKE_ENABLED: 'true') do
      conversation = max_chat
      Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Synthetic pending')).perform
      expect { account.with_lock { described_class.new(account: account, actor: manager).perform(conversation, result) } }
        .to raise_error(Corporate::DispatchInProgress)
      expect(conversation.reload.contact_id).to eq(source.id)
    end
  end

end
