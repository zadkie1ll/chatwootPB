class Corporate::RevocationJob < ApplicationJob
  queue_as :critical

  def perform(account_id, user_id)
    return unless Corporate.enabled?

    ActionCable.server.broadcast(
      Corporate.stream(account_id, user_id),
      { event: 'corporate.access_changed', data: { account_id: account_id } }
    )
  end
end
