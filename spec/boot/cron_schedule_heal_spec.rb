# frozen_string_literal: true

require "rails_helper"
require "open3"
require "net/http"

# A real worker against a real Redis (a database of its own, 15, which the
# example flushes): it loads config/schedule.yml at boot, and after FLUSHDB
# CronSchedule.heal! puts the seven jobs back on a heartbeat, logs it at WARN
# and counts it on the worker's /metrics. It processes only a queue nobody
# uses, so the cron jobs it enqueues never run. Slow (~20 s): boots Sidekiq.
RSpec.describe "Cron schedule self-heal in a running worker", :shells_out do # rubocop:disable RSpec/DescribeClass
  let(:redis_url) do
    # The suite's own Redis (REDIS_URL, config/initializers/sidekiq.rb), database 15.
    "#{Sidekiq.redis { |conn| conn.config.server_url }}/15"
  end
  let(:redis) { RedisClient.new(url: redis_url) }
  let(:names) { YAML.load_file(Rails.root.join("config/schedule.yml")).keys }
  let(:port) { TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] } }
  let(:output) { [] }
  let(:metrics_dir) { Dir.mktmpdir("cron-heal-prometheus") }

  def cron_job_names
    redis.call("SMEMBERS", "cron_jobs:default").map { |key| key.delete_prefix("cron_job:default:") }
  end

  def wait_for(seconds, what)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise "timed out after #{seconds}s waiting for #{what}\n#{output.join}" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.2
    end
  end

  def reloaded_total
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/metrics"))
    response.body[/^payhub_cron_schedule_reloaded_total (\S+)$/, 1].to_f
  end

  around do |example|
    webmock = WebMock::Config.instance
    saved = [webmock.allow_localhost, webmock.allow]
    webmock.allow_localhost = true # the worker's real /metrics
    example.run
  ensure
    webmock.allow_localhost, webmock.allow = saved
  end

  after do
    redis.call("FLUSHDB")
    FileUtils.rm_rf(metrics_dir)
  end

  it "reloads the seven cron jobs within a heartbeat of Redis losing them, logs WARN and counts it" do
    redis.call("FLUSHDB")
    env = { "REDIS_URL" => redis_url, "CRON_SCHEDULE_CHECK_SECONDS" => "1", "PROMETHEUS_MULTIPROC_DIR" => metrics_dir,
            "WORKER_METRICS_HOST" => "127.0.0.1", "WORKER_METRICS_PORT" => port.to_s, "METRICS_TOKEN" => nil }
    stdin, out, wait = Open3.popen2e(env, "bundle", "exec", "sidekiq", "-q", "cron_heal_spec", "-c", "1",
                                     chdir: Rails.root.to_s)
    stdin.close
    reader = Thread.new { out.each_line { |line| output << line } }

    wait_for(60, "the boot load") { cron_job_names.sort == names.sort && output.join.include?("Worker metrics on") }
    expect(output.join.scan("Cron Jobs - added job with name").size).to eq(7)
    expect(reloaded_total).to eq(0)

    redis.call("FLUSHDB")
    expect(cron_job_names).to be_empty

    wait_for(30, "the heal") { cron_job_names.sort == names.sort && output.join.include?("Cron schedule:") }
    expect(output.join).to match(/WARN.*Cron schedule: 7 of 7 jobs missing from Redis \(#{names.join(', ')}\); reloaded/)
    expect(reloaded_total).to eq(1)
  ensure
    if wait
      Process.kill("TERM", wait.pid)
      expect(wait.value.exitstatus).to eq(0), output.join
    end
    reader&.join(5)
  end
end
