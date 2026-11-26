class ChannelIdentity < ApplicationRecord
  belongs_to :account
  belongs_to :contact

  validates :channel, inclusion: { in: Corporate::Channels::SUPPORTED }
  validates :external_account_id, :external_user_id, presence: true, length: { maximum: 100 }
  validates :external_user_id, uniqueness: { scope: [:account_id, :channel, :external_account_id] }
  validates :verified_phone, format: { with: /\A\+[1-9]\d{6,14}\z/ }, allow_nil: true
  validate :consistent_account

  private

  def consistent_account
    errors.add(:contact, 'must belong to this account') unless contact&.account_id == account_id
  end
end
