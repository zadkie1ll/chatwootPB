require 'corporate_helper'

RSpec.describe Corporate::StaffService do
  let(:account) { Account.create!(name: 'Synthetic staff') }
  let(:supervisor) { staff(account, 'supervisor') }
  let(:manager) { staff(account, 'manager') }

  it 'creates a manager with only the core agent role' do
    user = described_class.new(account: account, actor: supervisor).create(
      name: 'Synthetic employee', email: 'new-staff@example.invalid', password: 'SyntheticPassword12!'
    )
    expect(Corporate.role(account, user)).to eq('manager')
    expect(AccountUser.find_by!(account: account, user: user)).to be_agent
    expect(user).to be_confirmed
  end

  it 'denies manager and technical staff management' do
    expect { described_class.new(account: account, actor: manager) }.to raise_error(Pundit::NotAuthorizedError)
    technical = staff(account, 'technical_admin')
    expect { described_class.new(account: account, actor: technical) }.to raise_error(Pundit::NotAuthorizedError)
  end

  it 'revokes disabled access and returns clients to the neutral pool with audit' do
    contact = client(account, owner: manager)
    conversation = chat(account, contact)
    old_token = manager.access_token.token
    described_class.new(account: account, actor: supervisor).disable(manager.id)
    expect(Corporate.role(account, manager)).to be_nil
    Corporate::DisabledStaffCleanupJob.perform_now(account.id, manager.id, supervisor.id)
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to be_nil
    expect(conversation.reload.assignee_id).to be_nil
    expect(manager.access_token.reload.token).not_to eq(old_token)
    expect(AssignmentAudit.find_by!(contact: contact).reason).to eq('employee_disabled')
  end

  it 'revokes access even while an external send outcome is unresolved' do
    contact = client(account, owner: manager)
    conversation = chat(account, contact)
    message = Messages::MessageBuilder.new(manager, conversation, ActionController::Parameters.new(content: 'Synthetic')).perform
    CorporateDelivery.find_by!(message: message).update!(state: 'unknown')
    described_class.new(account: account, actor: supervisor).disable(manager.id)
    expect(Corporate.role(account, manager)).to be_nil
    expect(CustomerOwnership.find_by!(contact: contact).owner_id).to eq(manager.id)
  end
end
