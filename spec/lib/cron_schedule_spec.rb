# frozen_string_literal: true

require "rails_helper"

RSpec.describe CronSchedule do
  let(:names) { YAML.load_file(Rails.root.join("config/schedule.yml")).keys }
  let(:loader) { instance_double(Sidekiq::Cron::ScheduleLoader, load_schedule: {}) }

  def jobs(present)
    present.map { |name| instance_double(Sidekiq::Cron::Job, name:) }
  end

  def reloads
    Metrics.counter(:cron_schedule_reloaded).get
  end

  before do
    described_class.instance_variable_set(:@last_check, nil)
    allow(Sidekiq::Cron::ScheduleLoader).to receive(:new).and_return(loader)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
  end

  # The hook is registered in configure_server: web and client processes (this
  # one included) never run it.
  it "is not hooked into a process that is not a Sidekiq server" do
    expect(Sidekiq).not_to be_server
    expect(Sidekiq.default_configuration[:lifecycle_events][:beat]).to be_empty
  end

  it "expects the seven jobs of config/schedule.yml" do
    expect(described_class.expected_names).to eq(names)
    expect(names.size).to eq(7)
  end

  it "reloads the schedule when a job is missing, logs at WARN and counts it" do
    allow(Sidekiq::Cron::Job).to receive(:all).and_return(jobs(names - %w[stuck_payment_sweeper]))

    expect { expect(described_class.heal!(now: 100.0)).to be(true) }.to change { reloads }.by(1)
    expect(loader).to have_received(:load_schedule).once
    expect(Rails.logger).to have_received(:warn)
      .with("Cron schedule: 1 of 7 jobs missing from Redis (stuck_payment_sweeper); " \
            "reloaded #{Sidekiq::Cron.configuration.cron_schedule_file}")
  end

  it "reloads when Redis has none of them (a flush)" do
    allow(Sidekiq::Cron::Job).to receive(:all).and_return([])

    expect(described_class.heal!(now: 100.0)).to be(true)
    expect(Rails.logger).to have_received(:warn).with(/7 of 7 jobs missing/)
  end

  it "does nothing when every job is there" do
    allow(Sidekiq::Cron::Job).to receive(:all).and_return(jobs(names + %w[a_dynamic_job]))

    expect { expect(described_class.heal!(now: 100.0)).to be(false) }.not_to(change { reloads })
    expect(loader).not_to have_received(:load_schedule)
    expect(Rails.logger).not_to have_received(:warn)
  end

  it "checks at most once per CHECK_SECONDS" do
    allow(Sidekiq::Cron::Job).to receive(:all).and_return([])

    described_class.heal!(now: 100.0)
    described_class.heal!(now: 100.0 + described_class::CHECK_SECONDS - 1)
    expect(Sidekiq::Cron::Job).to have_received(:all).once
    described_class.heal!(now: 100.0 + described_class::CHECK_SECONDS)
    expect(Sidekiq::Cron::Job).to have_received(:all).twice
  end

  it "logs the jobs sidekiq-cron rejected on reload" do
    allow(Sidekiq::Cron::Job).to receive(:all).and_return([])
    allow(loader).to receive(:load_schedule).and_return("expire_proposals" => ["'cron' -> bad: not a valid cronline"])

    expect(described_class.heal!(now: 100.0)).to be(true)
    expect(Rails.logger).to have_received(:error).with(/reload rejected .*expire_proposals/)
  end

  it "never raises into Sidekiq's heartbeat: Redis errors are logged and the next interval tries again" do
    allow(Sidekiq::Cron::Job).to receive(:all).and_raise(RedisClient::CannotConnectError, "Connection refused")

    expect(described_class.heal!(now: 100.0)).to be(false)
    expect(Rails.logger).to have_received(:error)
      .with("Cron schedule check failed: RedisClient::CannotConnectError: Connection refused")

    allow(Sidekiq::Cron::Job).to receive(:all).and_return([])
    expect(described_class.heal!(now: 100.0 + described_class::CHECK_SECONDS)).to be(true)
  end

  it "never raises when the reload itself fails" do
    allow(Sidekiq::Cron::Job).to receive(:all).and_return([])
    allow(loader).to receive(:load_schedule).and_raise(RedisClient::ReadOnlyError, "READONLY")

    expect { expect(described_class.heal!(now: 100.0)).to be(false) }.not_to(change { reloads })
  end
end
