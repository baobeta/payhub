# frozen_string_literal: true

# Production refuses to boot without real PSP endpoints, keys and webhook
# secrets (PspEnv), the same way it refuses to boot without AR_ENCRYPTION_*.
# after_initialize: the adapters are autoloaded app code.
Rails.application.config.after_initialize do
  PspEnv.verify_production!
end
