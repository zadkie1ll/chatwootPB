module CorporateConversationReads
  private

  def corporate_update_last_seen
    Corporate::PersonalReads.mark(@conversation, Current.user, at: Time.current)
    Notification::MarkConversationReadService.new(user: Current.user, account: Current.account, conversation: @conversation).perform
    render :update_last_seen
  end

  def corporate_mark_unread(last_seen_at)
    Corporate::PersonalReads.mark(@conversation, Current.user, at: last_seen_at, force: true)
    render :unread
  end
end
