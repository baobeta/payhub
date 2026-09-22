# typed: true

class Refund < ApplicationRecord
  belongs_to :payment
  has_many :ledger_entries, dependent: :restrict_with_exception

  STATES = %w[pending succeeded failed].freeze

  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: Currency::SUPPORTED }
  validates :state, inclusion: { in: STATES }
  validates :psp_reference, presence: true, uniqueness: true

  def self.generate_psp_reference = "phr_#{SecureRandom.hex(12)}"

  # The "sum of succeeded refunds <= captured" rule is NOT here: it spans rows
  # and needs the payment lock + ledger sum. See RefundService (Phase 5).
end
