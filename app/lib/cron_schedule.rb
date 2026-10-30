# typed: strict
# frozen_string_literal: true

# The sweepers' cron schedule lives in Redis. sidekiq-cron writes it there from
# config/schedule.yml once, when a worker starts, so a Redis that loses its
# data (a flush, a failover to an empty replica, a lost volume) would leave
# nothing polling stuck payments until someone restarted the worker. heal!
# runs on the worker's Sidekiq :beat (every 10 s, config/initializers/sidekiq.rb)
# and, at most once per CHECK_SECONDS, puts the schedule back if any job is missing.
module CronSchedule
  extend T::Sig

  CHECK_SECONDS = T.let(Integer(ENV.fetch("CRON_SCHEDULE_CHECK_SECONDS", "60")), Integer)

  @last_check = T.let(nil, T.nilable(Numeric))

  class << self
    extend T::Sig

    # Returns whether it reloaded the schedule. Never raises: it runs inside
    # Sidekiq's heartbeat. Sidekiq fires :beat only after a heartbeat reached
    # Redis, so an error here is logged and the check runs again next interval.
    sig { params(now: Numeric).returns(T::Boolean) }
    def heal!(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      last = @last_check
      return false if last && now - last < CHECK_SECONDS

      @last_check = now
      expected = expected_names
      missing = expected - Sidekiq::Cron::Job.all.map(&:name)
      return false if missing.empty?

      # The same load sidekiq-cron does at startup: source "schedule", and jobs
      # dropped from the file are destroyed. Each job is one hash keyed by its
      # name, so workers healing at once overwrite each other, never duplicate.
      # During a deploy that changes the file, an old worker can put back a job
      # the new one dropped (and drop the new ones) until the old one stops;
      # the next check of a new worker then restores the new file.
      errors = Sidekiq::Cron::ScheduleLoader.new.load_schedule
      Rails.logger.warn("Cron schedule: #{missing.size} of #{expected.size} jobs missing from Redis " \
                        "(#{missing.join(', ')}); reloaded #{schedule_file}")
      Rails.logger.error("Cron schedule: reload rejected #{errors.inspect}") if errors.present?
      Metrics.increment(:cron_schedule_reloaded)
      true
    rescue StandardError => e
      Rails.logger.error("Cron schedule check failed: #{e.class}: #{e.message}")
      false
    end

    # Parsed as sidekiq-cron's ScheduleLoader parses it (ERB, then YAML).
    sig { returns(T::Array[String]) }
    def expected_names
      Sidekiq::Cron::Support.load_yaml(ERB.new(File.read(schedule_file)).result).keys
    end

    sig { returns(String) }
    def schedule_file
      Sidekiq::Cron.configuration.cron_schedule_file
    end
  end
end
