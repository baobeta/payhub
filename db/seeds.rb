# typed: false
# frozen_string_literal: true

# `bin/rails db:seed` — the one seed command. Idempotent: safe to run twice.
#
# Creates a demo merchant (prints its API key ONCE — it is stored only as a
# digest) and a full FX table across every supported currency, so any
# currency pair can be priced. Rates are illustrative, not market data.

# ── FX rates: every pair among the supported currencies ─────────────────────
# Approximate mid-market rates to EUR; cross rates are derived from these.
TO_EUR = {
  "EUR" => BigDecimal("1"),
  "GBP" => BigDecimal("1.17"),
  "USD" => BigDecimal("0.92"),
  "VND" => BigDecimal("0.000037"),
  "THB" => BigDecimal("0.026"),
  "IDR" => BigDecimal("0.000058")
}.freeze

captured_at = Time.current
pairs = 0
Currency::SUPPORTED.product(Currency::SUPPORTED).each do |base, quote|
  next if base == quote

  rate = (TO_EUR.fetch(base) / TO_EUR.fetch(quote)).round(8)
  next if FxRate.exists?(base: base, quote: quote) # idempotent: don't pile up rows on re-seed

  FxRate.create!(base: base, quote: quote, rate: rate, captured_at: captured_at)
  pairs += 1
end
puts "fx_rates: #{pairs} new pair(s), #{FxRate.count} total"

# ── Demo merchant ───────────────────────────────────────────────────────────
if Merchant.exists?(name: "Demo Merchant")
  puts "merchant: Demo Merchant already exists (key was shown when first seeded)"
else
  merchant, raw_key = Merchant.create_with_api_key!(name: "Demo Merchant", default_currency: "EUR")
  puts <<~MSG

    merchant: #{merchant.id} (Demo Merchant, EUR)
    api key:  #{raw_key}

    This key is shown ONCE. Only its SHA-256 digest is stored.
    Try:
      curl -s -X POST localhost:3000/v1/payments \\
        -H "Authorization: Bearer #{raw_key}" \\
        -H "Idempotency-Key: $(uuidgen)" -H "Content-Type: application/json" \\
        -d '{"amount_minor":2500,"currency":"EUR","payment_method_token":"tok_visa"}'
  MSG
  _test_key, test_raw = ApiKey.issue!(merchant:, livemode: false, name: "Default test key")
  puts "Demo merchant TEST key (shown once): #{test_raw}"
end

# ── Demo merchant's first owner ─────────────────────────────────────────────
demo = Merchant.find_by(name: "Demo Merchant", livemode: true)
if demo && !demo.merchant_users.active.exists?(role: "owner") # authz-allow-role-check
  owner, token = MerchantUser.invite_first_owner!(merchant: demo, email: "owner@demo.payhub.local")
  InvitationMailer.invite(owner, token).deliver_now
  puts "\nDashboard owner invitation (also in MailCatcher): http://localhost:3000/dashboard/invitations/#{token}"
end
