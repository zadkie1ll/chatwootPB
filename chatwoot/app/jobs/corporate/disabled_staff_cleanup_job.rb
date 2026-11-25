class Corporate::DisabledStaffCleanupJob < ApplicationJob
  queue_as :default
  retry_on Corporate::DispatchInProgress, wait: 30.seconds, attempts: :unlimited

  def perform(account_id, user_id, actor_id)
    account = Account.find(account_id)
    return if CorporateMembership.exists?(account: account, user_id: user_id, active: true)

    CustomerOwnership.where(account: account, owner_id: user_id).find_each do |ownership|
      Corporate::OwnershipService.new(account: account, actor: account.users.find(actor_id)).transfer(
        contact: ownership.contact, owner_id: nil, reason: 'employee_disabled'
      )
    end
  end
end
