# frozen_string_literal: true

FactoryBot.define do
  factory :operator_proposal do
    payment
    proposed_by { create(:operator, role: "ops") }
    kind { "payment_transition" }
    payload { { "to_state" => "failed" } }
    reason_code { "psp_confirmed_outcome" }
    reason_text { "PSP confirmed the outcome" }
    case_reference { "OPS-1" }
    client_token { SecureRandom.uuid }

    trait :ledger_correction do
      kind { "ledger_correction" }
      payload do
        {
          "currency" => "EUR",
          "legs" => [
            { "account_kind" => "merchant_payable", "direction" => "credit", "amount_minor" => 100 },
            { "account_kind" => "psp_receivable", "direction" => "debit", "amount_minor" => 100 }
          ]
        }
      end
    end
  end
end
