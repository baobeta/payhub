# frozen_string_literal: true

namespace :merchants do
  # bin/rails "merchants:rotate_webhook_secret[<merchant_id>]"
  # Prints the new secret ONCE. The old one keeps signing for 24 hours.
  desc "Rotate a merchant's outbound webhook secret, keeping the old one valid for 24h"
  task :rotate_webhook_secret, [:merchant_id] => :environment do |_t, args|
    merchant = Merchant.find(args.fetch(:merchant_id))
    fresh = merchant.rotate_webhook_secret!
    puts <<~MSG
      merchant:   #{merchant.id} (#{merchant.name})
      new secret: #{fresh}

      Shown once. Until #{merchant.previous_webhook_secret_expires_at.utc.iso8601} every webhook
      carries two v1 signatures (new and old); verify against the new one, then stop accepting the old.
    MSG
  end
end
