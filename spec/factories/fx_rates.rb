FactoryBot.define do
  factory :fx_rate do
    base { "VND" }
    quote { "EUR" }
    rate { BigDecimal("0.000037") }
    captured_at { Time.current }
  end
end
