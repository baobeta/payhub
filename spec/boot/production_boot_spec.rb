# frozen_string_literal: true

require "rails_helper"
require "open3"

# Boots the app in production in a child process, with only the variables
# production requires. Catches boot-order mistakes that the test environment
# cannot see (e.g. a sig evaluated before Sorbet's production check level is
# set). Slow (a few seconds): it shells out to bin/rails.
RSpec.describe "Production boot", :shells_out do # rubocop:disable RSpec/DescribeClass
  let(:db) { ActiveRecord::Base.connection_db_config.configuration_hash }
  let(:env) do
    {
      "RAILS_ENV" => "production",
      "SECRET_KEY_BASE" => "x" * 64,
      "APP_HOST" => "payhub.example.com",
      "AR_ENCRYPTION_PRIMARY_KEY" => "primary-key-for-boot-spec",
      "AR_ENCRYPTION_DETERMINISTIC_KEY" => "deterministic-key-for-boot-spec",
      "AR_ENCRYPTION_KEY_DERIVATION_SALT" => "salt-for-boot-spec",
      "DATABASE_URL" => "postgres://#{db[:username]}:#{db[:password]}@#{db[:host]}:#{db[:port]}/#{db[:database]}",
      "REDIS_URL" => "redis://localhost:6379/0",
      "NORDPAY_URL" => "https://nordpay.example.com",
      "NORDPAY_API_KEY" => "np_live_boot_spec",
      "NORDPAY_WEBHOOK_SECRET" => "np_whsec_boot_spec",
      "KIRIPAY_URL" => "https://kiripay.example.com",
      "KIRIPAY_API_KEY" => "kp_live_boot_spec",
      "KIRIPAY_WEBHOOK_SECRET" => "kp_whsec_boot_spec"
    }
  end

  it "PR-1: boots with the production environment" do
    stdout, stderr, status = Open3.capture3(env, "bin/rails", "runner", "puts :booted", chdir: Rails.root.to_s)

    expect(status.success?).to be(true), "exit #{status.exitstatus}\n#{stderr}"
    expect(stdout).to include("booted")
  end
end
