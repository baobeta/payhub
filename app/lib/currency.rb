# Money is stored as integer minor units next to an ISO-4217 code.
# This is the ONLY place that knows how many minor units make one major unit.
# Never write `/ 100` anywhere else: VND has no minor unit, so 50000 is ₫50,000.
module Currency
  EXPONENT = {
    "EUR" => 2, "GBP" => 2, "USD" => 2, # Nordpay
    "VND" => 0, "THB" => 2, "IDR" => 2  # Kiripay
  }.freeze

  SUPPORTED = EXPONENT.keys.freeze

  class Unsupported < StandardError; end

  module_function

  def supported?(code) = EXPONENT.key?(code.to_s)

  def exponent(code)
    EXPONENT.fetch(code.to_s) { raise Unsupported, "unsupported currency #{code.inspect}" }
  end

  # 2500, "EUR" => "25.00"   50000, "VND" => "50000"
  def to_display(amount_minor, code)
    exp = exponent(code)
    return amount_minor.to_s if exp.zero?

    major, minor = amount_minor.abs.divmod(10**exp)
    sign = amount_minor.negative? ? "-" : ""
    "#{sign}#{major}.#{minor.to_s.rjust(exp, '0')}"
  end

  # What a PSP that speaks in major units wants: 2500, "EUR" => 25.0 ; 50000, "VND" => 50000
  # Returns a BigDecimal, never a Float, so it's exact.
  def to_major(amount_minor, code)
    BigDecimal(amount_minor) / (10**exponent(code))
  end

  def from_major(amount_major, code)
    (BigDecimal(amount_major.to_s) * (10**exponent(code))).to_i
  end
end
