source "https://rubygems.org"

ruby "3.2.6"

gem "rails", "~> 7.2.3", ">= 7.2.3.2"
gem "json", "~> 2.9" # json 3.x removed `quirks_mode`, which ActiveSupport 7.2's encoder still passes
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "bootsnap", require: false
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Background jobs — the PSP calls, status poller, and webhook sweepers all run here.
gem "sidekiq", "~> 7.3"

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

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "rspec-rails", "~> 7.1"
  gem "factory_bot_rails", "~> 6.4"
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :test do
  # Fails the suite on N+1 queries in the payment list endpoint.
  gem "prosopite", "~> 1.4"
  gem "pg_query", "~> 6.0" # prosopite needs it to fingerprint queries
  gem "webmock", "~> 3.24"
end
