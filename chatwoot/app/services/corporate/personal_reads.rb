class Corporate::PersonalReads
  def self.cache
    Current.corporate_read_cache ||= {}
  end

  def self.timestamp(conversation, user = Current.user)
    return conversation.agent_last_seen_at unless user.is_a?(User)

    key = [conversation.account_id, user.id, conversation.id]
    return cache[key] if cache.key?(key)

    view = CorporateConversationView.find_by(account_id: conversation.account_id, conversation: conversation, user: user)
    cache[key] = view ? view.last_seen_at : conversation.agent_last_seen_at
  end

  def self.preload(conversations, user)
    return unless user.is_a?(User)

    records = conversations.to_a
    records.each { |conversation| cache[[conversation.account_id, user.id, conversation.id]] = conversation.agent_last_seen_at }
    CorporateConversationView.where(user: user, conversation_id: records.map(&:id)).find_each do |view|
      cache[[view.account_id, user.id, view.conversation_id]] = view.last_seen_at
    end
  end

  def self.mark(conversation, user, at:, force: false)
    view = CorporateConversationView.create_or_find_by!(account: conversation.account, conversation: conversation, user: user) do |record|
      record.last_seen_at = at
    end
    if force || !recent_without_unread?(conversation, view)
      view.with_lock do
        view.update!(last_seen_at: force ? at : [view.last_seen_at, at].compact.max)
      end
    end
    cache[[conversation.account_id, user.id, conversation.id]] = view.last_seen_at
  end

  def self.recent_without_unread?(conversation, view)
    return false unless view.last_seen_at && view.last_seen_at > 1.hour.ago

    !conversation.messages.incoming.where(Message.arel_table[:created_at].gt(view.last_seen_at)).exists?
  end

  def self.count(conversation, user = Current.user)
    seen = timestamp(conversation, user)
    scope = conversation.messages.incoming
    scope = scope.where(Message.arel_table[:created_at].gt(seen)) if seen
    scope.count
  end

  def self.unread_rows(scope, user)
    conversations = Conversation.arel_table
    messages = Message.arel_table
    views = CorporateConversationView.arel_table.alias('corporate_reader_view')
    scope.joins(reader_join(conversations, views, user)).joins(:messages)
         .where(messages: { message_type: :incoming }).where(messages[:account_id].eq(conversations[:account_id]))
         .where(messages[:created_at].gt(seen_expression(conversations, views)))
  end

  def self.reader_join(conversations, views, user)
    condition = views[:conversation_id].eq(conversations[:id])
                                       .and(views[:account_id].eq(conversations[:account_id])).and(views[:user_id].eq(user.id))
    conversations.join(views, Arel::Nodes::OuterJoin).on(condition).join_sources
  end

  def self.seen_expression(conversations, views)
    values = [views[:last_seen_at], conversations[:agent_last_seen_at], Arel::Nodes.build_quoted(Time.at(0).utc)]
    Arel::Nodes::NamedFunction.new('COALESCE', values)
  end
end
