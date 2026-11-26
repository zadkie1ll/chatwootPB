json.meta do
  json.mine_count @conversations_count[:mine_count]
  json.assigned_count @conversations_count[:assigned_count]
  json.unassigned_count @conversations_count[:unassigned_count]
  json.all_count @conversations_count[:all_count]
    if Corporate.enabled?
      json.shared_count @conversations_count[:shared_count]
      json.mine_unread_count @conversations_count[:mine_unread_count]
      json.unassigned_unread_count @conversations_count[:unassigned_unread_count]
      json.shared_unread_count @conversations_count[:shared_unread_count]
      json.all_unread_count @conversations_count[:all_unread_count]
    end
end
