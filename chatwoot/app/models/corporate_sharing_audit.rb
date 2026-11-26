class CorporateSharingAudit < ApplicationRecord
  belongs_to :account
  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :subject_user, class_name: 'User', optional: true
  belongs_to :conversation, optional: true
  validates :action, inclusion: { in: %w[conversation_shared conversation_private absence_started absence_ended] }
  validate :consistent_account

  private

  def consistent_account
    errors.add(:conversation, 'must belong to this account') if conversation && conversation.account_id != account_id
    [actor, subject_user].compact.each do |member|
      errors.add(:base, 'staff must belong to this account') unless AccountUser.exists?(account_id: account_id, user_id: member.id)
    end
  end
end
