# Append-only. The database trigger rejects UPDATE/DELETE; these guards make
# the same rule visible from Ruby before a query is even sent.
class LedgerEntry < ApplicationRecord
  belongs_to :account, class_name: "LedgerAccount"
  belongs_to :payment, optional: true
  belongs_to :refund, optional: true

  DIRECTIONS = %w[debit credit].freeze

  validates :transfer_id, presence: true
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: Currency::SUPPORTED }

  def readonly? = persisted?

  # Signed amount for summing: credits positive, debits negative.
  def signed_minor = direction == "credit" ? amount_minor : -amount_minor
end
