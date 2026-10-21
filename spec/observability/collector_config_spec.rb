# frozen_string_literal: true

require "rails_helper"

# The dev collector (observability/otel-collector.yaml) must scrape web and
# worker separately and send the same bearer token /metrics checks
# (MetricsAuth). A drifted target or a dropped token only shows up as an
# empty Grafana panel, so pin them here.
RSpec.describe "OpenTelemetry collector config" do # rubocop:disable RSpec/DescribeClass, RSpec/MultipleDescribes
  let(:config) { YAML.safe_load_file(Rails.root.join("observability/otel-collector.yaml")) }
  let(:compose) { YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true) }
  let(:jobs) do
    config.dig("receivers", "prometheus", "config", "scrape_configs").index_by { |job| job["job_name"] }
  end
  let(:targets) { jobs.transform_values { |job| job["static_configs"].flat_map { |static| static["targets"] } } }

  def compose_env(service, key)
    compose.dig("services", service, "environment", key)
  end

  it "scrapes web and worker as separate jobs" do
    expect(targets.keys).to contain_exactly("payhub-web", "payhub-worker")
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
    expect(jobs.keys).to contain_exactly(compose_env("web", "OTEL_SERVICE_NAME"),
                                         compose_env("worker", "OTEL_SERVICE_NAME"))
  end

  it "sends METRICS_TOKEN as the bearer credentials on every scrape" do
    expect(jobs.values).to all(include("metrics_path" => "/metrics"))
    expect(jobs.values.map { |job| job.dig("authorization", "credentials") }).to all(include("METRICS_TOKEN"))
  end

  it "passes METRICS_TOKEN to the collector and the app from the same variable" do
    values = %w[otel-collector web worker].map { |service| compose_env(service, "METRICS_TOKEN") }
    expect(values.uniq.size).to eq(1)
    expect(values.first).to include("${METRICS_TOKEN")
  end
end

# The production collector (observability/otel-collector.production.yaml)
# reads container stdout, keeps 90 days queryable in ClickHouse and archives
# logs to S3 (PCI DSS 10.5.1). Every endpoint and secret comes from the
# environment, and the scrape jobs keep the dev names so ServiceName matches.
RSpec.describe "OpenTelemetry production collector config" do # rubocop:disable RSpec/DescribeClass
  let(:config) { YAML.safe_load_file(Rails.root.join("observability/otel-collector.production.yaml")) }
  let(:dev_config) { YAML.safe_load_file(Rails.root.join("observability/otel-collector.yaml")) }
  let(:jobs) do
    config.dig("receivers", "prometheus", "config", "scrape_configs").index_by { |job| job["job_name"] }
  end

  # [key, value] for every scalar in the tree, at any depth.
  def pairs(node)
    case node
    when Hash then node.flat_map { |key, value| value.is_a?(Enumerable) ? pairs(value) : [[key, value]] }
    when Array then node.flat_map { |value| pairs(value) }
    else []
    end
  end

  it "reads container stdout logs, never development.log" do
    include_paths = config.dig("receivers", "filelog", "include")
    expect(include_paths).to eq(["/var/lib/docker/containers/*/*-json.log"])
    expect(config.dig("receivers", "filelog", "operators").first).to include("type" => "container")
    expect(pairs(config).map(&:last).grep(String).join("\n")).not_to include("development.log")
  end

  # Request and job lines carry "kind"; every other structured line (psp_call,
  # webhook.*, settlement.*, …) carries "event", sometimes with its own "kind".
  # Dropping any of them would keep it out of the 12-month archive.
  it "keeps every PayHub JSON line: kind or event, whatever the value" do
    operators = config.dig("receivers", "filelog", "operators")
    payhub_filter = operators.select { |op| op["type"] == "filter" }.map { |op| op["expr"] }.grep(/attributes\./)
    expect(payhub_filter).to eq(["attributes.kind == nil and attributes.event == nil"])
    # Event lines have no "time" of their own, so attributes.time is Docker's,
    # in nanoseconds: the layout must take any number of fractional digits.
    expect(operators.select { |op| op["type"] == "time_parser" })
      .to contain_exactly(include("parse_from" => "attributes.time", "layout" => "2006-01-02T15:04:05.999999999Z07:00"))
  end

  it "keeps 90 days in ClickHouse and archives logs to S3" do
    expect(config.dig("exporters", "clickhouse", "ttl")).to eq("2160h")
    expect(config.dig("exporters", "awss3", "s3uploader", "s3_prefix")).to eq("payhub/logs")
    expect(config.dig("service", "pipelines", "logs", "exporters")).to include("clickhouse", "awss3")
  end

  it "takes every endpoint and credential from the environment" do
    clickhouse = config.dig("exporters", "clickhouse")
    expect(clickhouse.values_at("endpoint", "username", "password")).to all(start_with("${env:"))
    expect(config.dig("exporters", "awss3", "s3uploader").values_at("region", "s3_bucket")).to all(start_with("${env:"))
    secrets = pairs(config.slice("exporters", "receivers"))
              .select { |key, _| key.match?(/user|password|secret|token|credentials|region|bucket/) }
    expect(secrets.size).to be >= 6
    expect(secrets.map(&:last)).to all(start_with("${env:")) # no dev-style literal "otel"
  end

  it "scrapes web and worker from configured targets with METRICS_TOKEN" do
    targets = jobs.transform_values { |job| job["static_configs"].flat_map { |static| static["targets"] } }
    expect(targets).to eq("payhub-web" => ["${env:WEB_METRICS_TARGET}"],
                          "payhub-worker" => ["${env:WORKER_METRICS_TARGET}"])
    expect(jobs.values).to all(include("metrics_path" => "/metrics"))
    expect(jobs.values.map { |job| job.dig("authorization", "credentials") }).to all(include("METRICS_TOKEN"))
  end

  it "uses the dev config's job names, so ServiceName is the same in every environment" do
    dev_jobs = dev_config.dig("receivers", "prometheus", "config", "scrape_configs").pluck("job_name")
    expect(jobs.keys).to match_array(dev_jobs)
  end
end
