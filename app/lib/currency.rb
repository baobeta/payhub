# typed: strict
# frozen_string_literal: true

# Money is stored as integer minor units next to an ISO-4217 code.
# This is the ONLY place that knows how many minor units make one major unit.
# Never write `/ 100` anywhere else: VND has no minor unit, so 50000 is ₫50,000.
module Currency
  extend T::Sig

  EXPONENT = T.let(
    {
      "EUR" => 2, "GBP" => 2, "USD" => 2, # Nordpay
      "VND" => 0, "THB" => 2, "IDR" => 2  # Kiripay
    }.freeze,
    T::Hash[String, Integer]
  )

  SUPPORTED = T.let(EXPONENT.keys.freeze, T::Array[String])

  class Unsupported < StandardError; end

  class << self
    extend T::Sig

    sig { params(code: T.any(String, Symbol)).returns(T::Boolean) }
    def supported?(code) = EXPONENT.key?(code.to_s)

    sig { params(code: T.any(String, Symbol)).returns(Integer) }
    def exponent(code)
      EXPONENT.fetch(code.to_s) { raise Unsupported, "unsupported currency #{code.inspect}" }
    end

    # 2500, "EUR" => "25.00"   50000, "VND" => "50000"
    sig { params(amount_minor: Integer, code: T.any(String, Symbol)).returns(String) }
    def to_display(amount_minor, code)
      exp = exponent(code)
      return amount_minor.to_s if exp.zero?

      major, minor = amount_minor.abs.divmod(scale(exp))
      sign = amount_minor.negative? ? "-" : ""
      "#{sign}#{major}.#{minor.to_s.rjust(exp, '0')}"
    end

    # What a PSP that speaks in major units wants: 2500, "EUR" => 25.0 ; 50000, "VND" => 50000
    # Returns a BigDecimal, never a Float, so it is exact.
    sig { params(amount_minor: Integer, code: T.any(String, Symbol)).returns(BigDecimal) }
    def to_major(amount_minor, code)
      BigDecimal(amount_minor) / scale(exponent(code))
    end

    sig { params(amount_major: T.any(String, Integer, BigDecimal), code: T.any(String, Symbol)).returns(Integer) }
    def from_major(amount_major, code)
      (BigDecimal(amount_major.to_s) * scale(exponent(code))).to_i
    end

    private

    # 10**exp as an Integer. Sorbet types Integer#** as Numeric (negative
    # exponents yield Rational); exponents here are always >= 0.
    sig { params(exp: Integer).returns(Integer) }
    def scale(exp) = T.cast(10**exp, Integer)
  end
end
