# typed: true

# One line of a PSP's settlement report, as ingested (DECISIONS #18).
class SettlementLine < ApplicationRecord
  belongs_to :payment, optional: true
  belongs_to :refund, optional: true

  KINDS = %w[capture refund].freeze
  STATUSES = %w[matched unmatched mismatch].freeze

  validates :psp_name, :external_id, :psp_reference, :settled_on, :booked_at, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :currency, inclusion: { in: Currency::SUPPORTED }

  scope :discrepancies, -> { where.not(status: "matched") }
end
