class CorporateConversationView < ApplicationRecord
  belongs_to :account
  belongs_to :conversation
  belongs_to :user
  validates :conversation_id, uniqueness: { scope: [:account_id, :user_id] }
  validate :consistent_account

  private

  def consistent_account
    errors.add(:conversation, 'must belong to this account') unless conversation&.account_id == account_id
    errors.add(:user, 'must belong to this account') unless AccountUser.exists?(account_id: account_id, user_id: user_id)
  end
end
