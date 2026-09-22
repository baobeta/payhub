# typed: true

# Transactional outbox: created in the same DB transaction as the state change
# it announces, delivered later by the sweeper (Phase 6).
class OutboundEvent < ApplicationRecord
  belongs_to :merchant
  belongs_to :payment, optional: true
  has_many :delivery_attempts, class_name: "OutboundDeliveryAttempt", dependent: :restrict_with_exception

  STATES = %w[pending delivered dead].freeze
  MAX_ATTEMPTS = 8

  validates :event_type, :payload, presence: true
  validates :state, inclusion: { in: STATES }

  scope :due, -> { where(state: "pending").where(next_attempt_at: ..Time.current).order(:next_attempt_at) }
end
