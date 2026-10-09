# frozen_string_literal: true

namespace :e2e do
  desc "Seed a merchant, a support user with a known TOTP secret, and a captured payment (test env only)"
  task seed: :environment do
    abort "e2e:seed runs only in RAILS_ENV=test" unless Rails.env.test?

    merchant, = Merchant.create_with_api_key!(name: "E2E Merchant", default_currency: "EUR")
    MerchantUser.create!(merchant:, email: "support@e2e.test", role: "support", password: "e2e password 1234",
                         otp_secret: "JBSWY3DPEHPK3PXP", otp_enabled_at: Time.current, accepted_at: Time.current)
    payment = Payment.create!(merchant:, amount_minor: 2500, currency: "EUR", merchant_currency: "EUR", fx_rate: 1,
                              psp_name: "nordpay", psp_reference: Payment.generate_psp_reference,
                              payment_method_token: "tok_visa")
    payment.transition!(:authorized, sort_key: 1.second.from_now, source: "worker")
    payment.transition!(:captured, sort_key: 2.seconds.from_now, source: "worker")
    Ledger.record_capture!(payment, 2500)
    payment.update!(captured_minor: 2500)
    puts payment.id
  end

  desc "Seed two operators and a stuck payment for the operator propose/approve flow (test env only)"
  task seed_ops: :environment do
    abort "e2e:seed_ops runs only in RAILS_ENV=test" unless Rails.env.test?

    merchant, = Merchant.create_with_api_key!(name: "E2E Ops Merchant", default_currency: "EUR")
    Operator.create!(email: "ops@e2e.test", name: "Ops", role: "ops", password: "e2e password 1234",
                     otp_secret: "JBSWY3DPEHPK3PXP", otp_enabled_at: Time.current, accepted_at: Time.current)
    Operator.create!(email: "approver@e2e.test", name: "Approver", role: "approver", password: "e2e password 1234",
                     otp_secret: "KRSXG5CTMVRXEZLU", otp_enabled_at: Time.current, accepted_at: Time.current)

    payment = Payment.create!(merchant:, amount_minor: 3000, currency: "EUR", merchant_currency: "EUR", fx_rate: 1,
                              psp_name: "nordpay", psp_reference: Payment.generate_psp_reference,
                              payment_method_token: "tok_visa")
    payment.transition!(:unknown, sort_key: 1.second.from_now, source: "worker")
    PspCall.create!(psp_name: "nordpay", operation: "create", psp_reference: payment.psp_reference,
                    http_status: nil, outcome: "timeout", duration_ms: 8_000, sent_at: Time.current,
                    request_redacted: {}, response_redacted: {})
    puts payment.id
  end
end
