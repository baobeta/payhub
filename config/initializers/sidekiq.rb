# typed: false
# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"

Sidekiq.configure_server do |config|
  config.redis = { url: PayhubConfig.redis_url(Rails.env.to_s, ENV["REDIS_URL"]) }

  # Register the periodic sweepers from config/schedule.yml. Idempotent: an
  # existing job with the same name is updated, not duplicated. sidekiq-cron
  # loads the file itself on :startup (source "schedule": jobs dropped from it
  # are deleted). If Redis loses them later, CronSchedule.heal! (on Sidekiq's
  # 10-second :beat, checking every CRON_SCHEDULE_CHECK_SECONDS, 60) loads it again.
  Sidekiq::Cron.configure { |cron| cron.cron_schedule_file = Rails.root.join("config/schedule.yml").to_s }
  config.on(:beat) { CronSchedule.heal! }

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
  config.redis = { url: PayhubConfig.redis_url(Rails.env.to_s, ENV["REDIS_URL"]) }
end
