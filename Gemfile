source "https://rubygems.org"

ruby "3.3.12"

gem "rails", "~> 8.1.3"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "bootsnap", require: false
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Background jobs — the PSP calls, status poller, and webhook sweepers all run here.
gem "sidekiq", "~> 7.3"
# Periodic jobs (sweepers) scheduled from config/schedule.yml.
gem "sidekiq-cron", "~> 2.0"
# Sidekiq 7.3 calls ConnectionPool::TimedStack#pop(timeout); connection_pool 3.x removed that
# argument and the scheduler thread dies at boot. Pin until Sidekiq 8.
gem "connection_pool", "< 3"

# Outbound HTTP to the PSP simulators. Faraday gives us per-request timeouts
# and a retry middleware that we control (we must NOT retry blindly).
gem "faraday", "~> 2.12"
gem "faraday-retry", "~> 2.2"

# Per-merchant rate limiting -> 429 + Retry-After.
gem "rack-attack", "~> 6.7"

# Prometheus-style counters for /metrics.
gem "prometheus-client", "~> 4.2"

# JSON log lines: one per request and per job.
gem "lograge", "~> 0.14"

# Distributed tracing via OpenTelemetry OTLP.
gem "opentelemetry-sdk", "~> 1.8"
gem "opentelemetry-exporter-otlp", "~> 0.30"
gem "opentelemetry-instrumentation-all", "~> 0.80"

# Gradual static typing. Runtime sigs are checked in dev/test and
# stripped to no-ops in production via T::Configuration (see initializer).
gem "sorbet-runtime"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "rspec-rails", "~> 7.1"
  gem "factory_bot_rails", "~> 6.4"
  gem "brakeman", require: false

  gem "rubocop-rails-omakase", require: false
  gem "rubocop-rspec", require: false
  gem "rubocop-performance", require: false
end

group :development do
  gem "sorbet", require: false
  gem "tapioca", require: false
end

group :test do
  # Fails the suite on N+1 queries in the payment list endpoint.
  gem "prosopite", "~> 1.4"
  gem "pg_query", "~> 6.0" # prosopite needs it to fingerprint queries
  gem "webmock", "~> 3.24"
end
