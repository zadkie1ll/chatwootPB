class Corporate::SharingChangedJob < ApplicationJob
  queue_as :critical

  def perform(account_id, reduced, except_user_id = nil)
    account = Account.find_by(id: account_id)
    return unless Corporate.enabled? && account&.active?

    CorporateMembership.where(account: account, active: true, role: %w[manager supervisor]).where.not(user_id: except_user_id).find_each do |member|
      event = reduced ? 'corporate.access_changed' : 'corporate.sharing_changed'
      ActionCable.server.broadcast(Corporate.stream(account.id, member.user_id), { event: event, data: { account_id: account.id } })
    end
  end
end
