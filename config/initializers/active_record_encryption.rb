# frozen_string_literal: true

# Encrypts TOTP secrets at rest (merchant_users.otp_secret, operators.otp_secret).
# Production must set all three variables; `bin/rails db:encryption:init`
# prints fresh values. Dev and test use fixed values so fixtures and seeds
# stay readable across machines. They protect nothing and must never be reused.
keys = {
  primary_key: ENV["AR_ENCRYPTION_PRIMARY_KEY"],
  deterministic_key: ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"],
  key_derivation_salt: ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
}

if keys.values.any?(&:blank?)
  raise "Set AR_ENCRYPTION_* environment variables (bin/rails db:encryption:init)" if Rails.env.production?

  keys = {
    primary_key: "dev-only-primary-key-payhub-0000000000",
    deterministic_key: "dev-only-deterministic-key-payhub-00000",
    key_derivation_salt: "dev-only-key-derivation-salt-payhub-000"
  }
end

Rails.application.config.active_record.encryption.primary_key = keys[:primary_key]
Rails.application.config.active_record.encryption.deterministic_key = keys[:deterministic_key]
Rails.application.config.active_record.encryption.key_derivation_salt = keys[:key_derivation_salt]
