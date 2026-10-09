# frozen_string_literal: true

FactoryBot.define do
  factory :merchant_user do
    merchant
    sequence(:email) { |n| "user#{n}@example.com" }
    name { "Sam" }
    role { "admin" }
    password { "correct horse battery staple" }
    accepted_at { Time.current }
    otp_secret { ROTP::Base32.random }
    otp_enabled_at { Time.current }

    trait :invited do
      password { nil }
      accepted_at { nil }
      otp_enabled_at { nil }
    end
  end
end
