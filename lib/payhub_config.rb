# typed: strict
# frozen_string_literal: true

# Defaults for environment switches that must be safe in production.
module PayhubConfig
  extend T::Sig

  # The public demo needs no login (README "Dashboards"). In production it is
  # off unless DEMO_ENABLED=true is set on purpose, e.g. on a demo-only host.
  sig { params(rails_env: String, flag: T.nilable(String)).returns(T::Boolean) }
  def self.demo_enabled_default(rails_env, flag)
    return flag == "true" unless flag.nil?

    rails_env != "production"
  end

  # Sidekiq, the PSP circuit and production's cache all use this Redis. Compose
  # publishes its Redis on host port 6380 (6379 is often a Homebrew Redis), so
  # Rails, rspec and Sidekiq run on the host find it there. Production keeps the
  # plain default; set REDIS_URL anywhere but one host (README "Configuration").
  sig { params(rails_env: String, url: T.nilable(String)).returns(String) }
  def self.redis_url(rails_env, url)
    return url unless url.nil?

    rails_env == "production" ? "redis://localhost:6379/0" : "redis://localhost:6380/0"
  end
end
