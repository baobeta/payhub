class FxRate < ApplicationRecord
  validates :base, :quote, inclusion: { in: Currency::SUPPORTED }
  validates :rate, numericality: { greater_than: 0 }
  validates :captured_at, presence: true

  class Missing < StandardError; end

  # The latest known rate for a pair. Callers COPY the result onto the payment;
  # nothing ever joins to this table at read time.
  def self.latest!(base, quote)
    return BigDecimal("1") if base == quote

    where(base: base, quote: quote).order(captured_at: :desc).limit(1).pick(:rate) ||
      raise(Missing, "no fx rate for #{base}->#{quote}")
  end
end
