source "https://rubygems.org"

ruby "3.3.12"

gem "rails", "~> 8.1.4"
gem "pg", "~> 1.1"
gem "puma", ">= 6.0", "< 9" # MetricsExporter needs Puma::LogWriter (6+)
gem "bootsnap", require: false
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Background jobs — the PSP calls, status poller, and webhook sweepers all run here.
gem "sidekiq", "~> 8.0"
# Periodic jobs (sweepers) scheduled from config/schedule.yml.
gem "sidekiq-cron", "~> 2.0"

# Outbound HTTP to the PSP simulators. Faraday gives us per-request timeouts
# and a retry middleware that we control (we must NOT retry blindly).
gem "faraday", "~> 2.15"
gem "faraday-retry", "~> 2.2"
gem "csv", "~> 3.3" # settlement reports (DECISIONS #18); no longer a default gem from Ruby 3.4

# Per-merchant rate limiting -> 429 + Retry-After.
gem "rack-attack", "~> 6.7"
# Production's Rails.cache (Rack::Attack counters shared by every process) is
# Redis, the one Sidekiq already uses; RedisCacheStore needs this client.
gem "redis", "~> 5.4"

# Prometheus-style counters for /metrics.
gem "prometheus-client", "~> 5.0"

# JSON log lines: one per request and per job.
gem "lograge", "~> 0.15"

# Distributed tracing via OpenTelemetry OTLP.
gem "opentelemetry-sdk", "~> 1.8"
gem "opentelemetry-exporter-otlp", "~> 0.37"
gem "opentelemetry-instrumentation-all", "~> 0.99"

# Gradual static typing. Runtime sigs are checked in dev/test and
# stripped to no-ops in production via T::Configuration (see initializer).
gem "sorbet-runtime"

# Refuses migrations that would lock a busy table (an index built without
# CONCURRENTLY, a column rewrite) and sets lock and statement timeouts on the
# migration connection. Default group: production runs the migrations
# (RUN_MIGRATIONS=true), so the checks and timeouts must load there too.
gem "strong_migrations", "~> 2.0"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "rspec-rails", "~> 8.0"
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
  gem "prosopite", "~> 2.2"
  gem "pg_query", "~> 6.2" # prosopite needs it to fingerprint queries
  gem "webmock", "~> 3.24"
  # Line and branch coverage, started first thing in spec_helper.rb.
  gem "simplecov", "~> 0.22", require: false
end

gem "vite_rails", "~> 3.0"

gem "bcrypt", "~> 3.1"

gem "rotp", "~> 6.3"

gem "rqrcode", "~> 2.2"
