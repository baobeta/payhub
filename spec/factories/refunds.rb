FactoryBot.define do
  factory :refund do
    payment
    amount_minor { 500 }
    currency { payment.currency }
    state { "pending" }
    psp_reference { Refund.generate_psp_reference }

    # A pending refund always has its ledger reservation (CreateRefund writes
    # both in one transaction, DECISIONS #16); a factory refund must too.
    after(:create) { |refund| Ledger.reserve_refund!(refund) if refund.state == "pending" }
  end
end
