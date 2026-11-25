class AssignmentAudit < ApplicationRecord
  belongs_to :account
  belongs_to :contact
  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :old_owner, class_name: 'User', optional: true
  belongs_to :new_owner, class_name: 'User', optional: true

  validates :reason, presence: true, length: { maximum: 500 }
  validates :source, inclusion: { in: %w[user bitrix24] }
  validates :actor, presence: true, if: -> { source == 'user' }
  validates :correlation_id, presence: true
  validates :assignment_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
