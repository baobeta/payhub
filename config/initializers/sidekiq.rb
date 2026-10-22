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

  # Jobs raise counters the web scrape never sees (each service has its own
  # metrics directory), so the worker serves its own /metrics on
  # WORKER_METRICS_PORT (9394), with the same token rule as the web endpoint.
  metrics_server = nil
  config.on(:startup) { metrics_server = MetricsExporter.start! }
  # :shutdown fires as Sidekiq starts draining, so a scrape during the drain
  # misses; increments made after it are lost with the process anyway.
  config.on(:shutdown) { metrics_server&.stop(true) }
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
