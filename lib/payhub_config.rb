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
end
