class CorporateCrmLink < ApplicationRecord
  belongs_to :account
  belongs_to :contact
  belongs_to :conversation
  belongs_to :actor, class_name: 'User'
  validates :contact_id, uniqueness: { scope: :account_id }
  validates :external_deal_id, uniqueness: { scope: [:account_id, :entity_type] }, allow_nil: true
  validates :sync_state, inclusion: { in: %w[unlinked pending sending applied unknown not_found error] }
  validates :entity_type, inclusion: { in: %w[deal lead] }
  validate :consistent_account

  def dispatch_unresolved?
    %w[sending unknown].include?(sync_state)
  end

  private

  def consistent_account
    errors.add(:contact, 'account mismatch') unless contact&.account_id == account_id
    errors.add(:conversation, 'contact mismatch') unless conversation&.account_id == account_id && conversation&.contact_id == contact_id
  end
end
