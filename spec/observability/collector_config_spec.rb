# frozen_string_literal: true

require "rails_helper"

# The dev collector (observability/otel-collector.yaml) must scrape web and
# worker separately and send the same bearer token /metrics checks
# (MetricsAuth). A drifted target or a dropped token only shows up as an
# empty Grafana panel, so pin them here.
RSpec.describe "OpenTelemetry collector config" do # rubocop:disable RSpec/DescribeClass
  let(:config) { YAML.safe_load_file(Rails.root.join("observability/otel-collector.yaml")) }
  let(:compose) { YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true) }
  let(:jobs) do
    config.dig("receivers", "prometheus", "config", "scrape_configs").index_by { |job| job["job_name"] }
  end
  let(:targets) { jobs.transform_values { |job| job["static_configs"].flat_map { |static| static["targets"] } } }
  let(:app_jobs) { jobs.except("otelcol") }

  def compose_env(service, key)
    compose.dig("services", service, "environment", key)
  end

  it "scrapes web and worker as separate jobs" do
    expect(targets.keys).to contain_exactly("payhub-web", "payhub-worker", "otelcol")
    expect(targets["payhub-web"]).to eq(["web:3000"])
    expect(targets["payhub-worker"].size).to eq(1)
  end

  it "scrapes the worker on MetricsExporter's default port" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("WORKER_METRICS_PORT", anything) { |_key, default| default }
    port = nil
    allow(Puma::Server).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      server = original.call(*args, **kwargs)
      allow(server).to receive(:add_tcp_listener) { |_host, listen_port| port = listen_port }
      allow(server).to receive(:run)
      server
    end

    MetricsExporter.start!

    expect(targets["payhub-worker"]).to eq(["worker:#{port}"])
  end

  it "names each job after the service's OTEL_SERVICE_NAME, so ClickHouse ServiceName matches traces" do
    expect(app_jobs.keys).to contain_exactly(compose_env("web", "OTEL_SERVICE_NAME"),
                                             compose_env("worker", "OTEL_SERVICE_NAME"))
  end

  it "sends METRICS_TOKEN as the bearer credentials on every app scrape" do
    expect(app_jobs.values).to all(include("metrics_path" => "/metrics"))
    expect(app_jobs.values.map { |job| job.dig("authorization", "credentials") }).to all(include("METRICS_TOKEN"))
  end

  # The collector's own metrics (export failures, queue size) land in
  # ClickHouse as ServiceName 'otelcol', where the alert rules read them.
  it "scrapes the collector's own metrics from the address it serves them on" do
    telemetry = config.dig("service", "telemetry", "metrics")
    expect(telemetry).to include("level" => "normal")
    expect(targets["otelcol"]).to eq([telemetry["address"]])
    expect(jobs["otelcol"]).not_to have_key("authorization")
  end

  it "passes METRICS_TOKEN to the collector and the app from the same variable" do
    values = %w[otel-collector web worker].map { |service| compose_env(service, "METRICS_TOKEN") }
    expect(values.uniq.size).to eq(1)
    expect(values.first).to include("${METRICS_TOKEN")
  end
end
