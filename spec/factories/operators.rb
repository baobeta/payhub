# frozen_string_literal: true

FactoryBot.define do
  factory :operator do
    sequence(:email) { |n| "operator#{n}@example.com" }
    name { "Alex" }
    role { "support" }
    password { "correct horse battery staple" }
    accepted_at { Time.current }
    otp_secret { ROTP::Base32.random }
    otp_enabled_at { Time.current }
  end
end
