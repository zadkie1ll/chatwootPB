class CorporateInboxReceipt < ApplicationRecord
  belongs_to :account
  belongs_to :message, optional: true
  validates :event_key, presence: true, uniqueness: { scope: :account_id }, length: { maximum: 255 }
end
