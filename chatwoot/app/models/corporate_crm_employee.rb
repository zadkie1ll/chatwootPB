class CorporateCrmEmployee < ApplicationRecord
  belongs_to :account
  belongs_to :user
  validates :external_user_id, format: { with: /\A[1-9]\d{0,17}\z/ }, uniqueness: { scope: :account_id }
  validates :user_id, uniqueness: { scope: :account_id }
  validate :active_business_member

  private

  def active_business_member
    errors.add(:user, 'must be an active manager') unless Corporate.role(account, user) == 'manager'
  end
end
