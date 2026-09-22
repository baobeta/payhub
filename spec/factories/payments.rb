FactoryBot.define do
  factory :payment do
    merchant
    amount_minor { 2500 }
    currency { "EUR" }
    merchant_currency { "EUR" }
    fx_rate { 1 }
    psp_name { "nordpay" }
    psp_reference { Payment.generate_psp_reference }
    payment_method_token { "tok_visa" }

    trait :vnd do
      currency { "VND" }
      amount_minor { 500_000 }
      psp_name { "kiripay" }
      fx_rate { BigDecimal("0.000037") }
    end
  end
end
