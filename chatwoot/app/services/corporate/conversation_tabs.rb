class Corporate::ConversationTabs
  def initialize(scope, user, account:)
    @scope = Conversation.where(id: scope.unscope(:order).select(:id))
    @user = user
    @account = account
  end

  def counts
    total = aggregate(@scope)
    unread = aggregate(Corporate::PersonalReads.unread_rows(@scope, @user))
    {
      mine_count: total[0], unassigned_count: total[1], shared_count: total[2], all_count: total[3],
      assigned_count: total[3] - total[1], mine_unread_count: unread[0], unassigned_unread_count: unread[1],
      shared_unread_count: unread[2], all_unread_count: unread[3]
    }
  end

  private

  def aggregate(scope)
    conversations = Conversation.arel_table
    shared = Corporate::Visibility.shared_conversations(@account).select(:id).arel
    conditions = [conversations[:assignee_id].eq(@user.id),
                  conversations[:assignee_id].eq(nil).and(conversations[:assignee_agent_bot_id].eq(nil)), conversations[:id].in(shared)]
    fields = conditions.map do |condition|
      conditional_count(condition)
    end
    scope.unscope(:order).pick(*fields, conversations[:id].count) || [0, 0, 0, 0]
  end

  def conditional_count(condition)
    sum = Arel::Nodes::Case.new.when(condition).then(1).else(0).sum
    Arel::Nodes::NamedFunction.new('COALESCE', [sum, Arel::Nodes.build_quoted(0)])
  end
end
