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
    return value || simulator_default unless Rails.env.production?
    raise Missing, "Set #{name} for production (no simulator fallback)" if value.blank?
    raise Missing, "#{name} is set to the simulator's test value" if value == simulator_default

    value
  end
end
