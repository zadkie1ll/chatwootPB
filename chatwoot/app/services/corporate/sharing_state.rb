class Corporate::SharingState
  def self.absent_ids(account)
    Current.corporate_absence_cache ||= {}
    Current.corporate_absence_cache[account.id] ||= Corporate::Visibility.absent_members(account).pluck(:user_id)
  end

  def self.for(conversation, user)
    owner_id = conversation.contact.customer_ownership&.owner_id
    manual = conversation.corporate_conversation_share.present?
    absence = owner_id.present? && absent_ids(conversation.account).include?(owner_id)
    {
      shared: manual || absence, manual: manual, absence: absence, owner_id: owner_id,
      can_manage: Corporate.role(conversation.account, user) == 'supervisor' || (user.present? && owner_id.present? && owner_id == user.id)
    }
  end
end
