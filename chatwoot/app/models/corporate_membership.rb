class CorporateMembership < ApplicationRecord
  belongs_to :account
  belongs_to :user

  validates :role, inclusion: { in: %w[manager supervisor technical_admin] }
  validates :user_id, uniqueness: { scope: :account_id }
  validate :account_membership_exists

  private

  def account_membership_exists
    return if AccountUser.exists?(account_id: account_id, user_id: user_id)

    errors.add(:user, 'must belong to this account')
  end
end
