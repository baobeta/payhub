FactoryBot.define do
  factory :merchant do
    sequence(:name) { |n| "Merchant #{n}" }
    api_key_digest { Merchant.digest("sk_test_#{SecureRandom.hex(8)}") }
    webhook_secret { SecureRandom.hex(16) }
    default_currency { "EUR" }
  end
end
