# typed: true

# One merchant capture request (DECISIONS #20). pending → succeeded | failed.
class Capture < ApplicationRecord
  belongs_to :payment

  STATES = %w[pending succeeded failed].freeze

  validates :state, inclusion: { in: STATES }
  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validates :base_captured_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :pending, -> { where(state: "pending") }

  # The PSP's running total once this capture has landed.
  def target_minor = base_captured_minor + amount_minor
end
