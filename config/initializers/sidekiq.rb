# typed: false
# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"

Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }

  # Register the periodic sweepers from config/schedule.yml. Idempotent: an
  # existing job with the same name is updated, not duplicated.
  schedule = Rails.root.join("config/schedule.yml")
  Sidekiq::Cron::Job.load_from_hash!(YAML.load_file(schedule)) if File.exist?(schedule)
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
