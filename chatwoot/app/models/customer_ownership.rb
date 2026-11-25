class CustomerOwnership < ApplicationRecord
  belongs_to :account
  belongs_to :contact
  belongs_to :owner, class_name: 'User', optional: true

  validates :contact_id, uniqueness: { scope: :account_id }
  validate :consistent_account
  validate :eligible_owner

  private

  def consistent_account
    errors.add(:contact, 'must belong to this account') unless contact&.account_id == account_id
  end

  def eligible_owner
    return if owner_id.nil?
    return if CorporateMembership.exists?(account_id: account_id, user_id: owner_id, active: true, role: 'manager')

    errors.add(:owner, 'must be an active manager in this account')
  end
end
