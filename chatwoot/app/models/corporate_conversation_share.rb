class CorporateConversationShare < ApplicationRecord
  belongs_to :account
  belongs_to :conversation
  belongs_to :shared_by, class_name: 'User', optional: true
  validates :conversation_id, uniqueness: { scope: :account_id }
  validate :consistent_account

  private

  def consistent_account
    errors.add(:conversation, 'must belong to this account') unless conversation&.account_id == account_id
    errors.add(:shared_by, 'must belong to this account') if shared_by && !AccountUser.exists?(account_id: account_id, user_id: shared_by_id)
  end
end
