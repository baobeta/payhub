FactoryBot.define do
  factory :refund do
    payment
    amount_minor { 500 }
    currency { payment.currency }
    state { "pending" }
    psp_reference { Refund.generate_psp_reference }
  end
end
