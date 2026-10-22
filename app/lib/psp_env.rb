# typed: strict
# frozen_string_literal: true

# PSP endpoints, keys and webhook secrets. Development and test talk to the
# simulators with their well-known defaults; production must be told every
# value, and is never allowed to run on a simulator default.
module PspEnv
  extend T::Sig

  class Missing < StandardError; end

  sig { params(name: String, simulator_default: String).returns(String) }
  def self.fetch(name, simulator_default)
    value = ENV[name]
    return value.presence || simulator_default unless Rails.env.production?
    raise Missing, "Set #{name} for production (no simulator fallback)" if value.blank?
    raise Missing, "#{name} is set to the simulator's test value" if value == simulator_default

    value
  end

  # Called at boot (config/initializers/psp_credentials.rb). Building each
  # adapter reads every PSP variable, so a missing or simulator value stops
  # the deploy instead of failing the first payment or webhook.
  sig { void }
  def self.verify_production!
    return unless Rails.env.production?

    PspRouter::ADAPTERS.each_value(&:new)
  end
end
