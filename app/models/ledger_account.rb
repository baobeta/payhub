# typed: true

class LedgerAccount < ApplicationRecord
  belongs_to :merchant
  has_many :entries, class_name: "LedgerEntry", foreign_key: :account_id, dependent: :restrict_with_exception

  KINDS = %w[psp_receivable merchant_payable refunds_paid].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :currency, inclusion: { in: Currency::SUPPORTED }
  validates :kind, uniqueness: { scope: %i[merchant_id currency] }

  # Created lazily on first use; the unique index makes a race harmless.
  def self.for(merchant, kind, currency)
    find_or_create_by!(merchant: merchant, kind: kind, currency: currency)
  rescue ActiveRecord::RecordNotUnique
    find_by!(merchant: merchant, kind: kind, currency: currency)
  end

  # Balance is always derived. credits - debits, never a cached column.
  def balance_minor
    # SUM over bigint is `numeric` in Postgres; amounts are integers by contract.
    entries.sum(Arel.sql("CASE direction WHEN 'credit' THEN amount_minor ELSE -amount_minor END")).to_i
  end
end
