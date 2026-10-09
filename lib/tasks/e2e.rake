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
end
