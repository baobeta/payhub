# frozen_string_literal: true

require "rails_helper"

# The production collector (observability/otel-collector.production.yaml)
# reads web's and worker's stdout from Docker, keeps 90 days queryable in
# ClickHouse and archives every PayHub log line to S3 (PCI DSS 10.5.1). A
# dropped line, a restart that skips ahead, or a literal secret would only
# show up in an audit, so pin them here.
RSpec.describe "OpenTelemetry production collector config" do # rubocop:disable RSpec/DescribeClass
  let(:config) { YAML.safe_load_file(Rails.root.join("observability/otel-collector.production.yaml")) }
  let(:dev_config) { YAML.safe_load_file(Rails.root.join("observability/otel-collector.yaml")) }
  let(:filelog) { config.dig("receivers", "filelog") }
  let(:operators) { filelog["operators"] }
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

  # Go's (?P<name>) is Ruby's (?<name>); the rest of these patterns is shared.
  def ruby_regex(go_pattern)
    Regexp.new(go_pattern.gsub("(?P<", "(?<"))
  end

  it "reads container stdout logs, rotated files included, never development.log" do
    expect(filelog["include"]).to eq(["/var/lib/docker/containers/*/*-json.log*"])
    expect(operators.first).to include("type" => "container", "format" => "docker")
    expect(pairs(config).map(&:last).grep(String).join("\n")).not_to include("development.log")
  end

  it "checkpoints reads and queues ClickHouse exports on a persistent disk" do
    expect(config.dig("extensions", "file_storage", "directory")).to eq("/var/lib/otelcol/storage")
    expect(config.dig("service", "extensions")).to include("file_storage")
    expect(filelog["storage"]).to eq("file_storage")
    expect(config.dig("exporters", "clickhouse", "sending_queue")).to include("enabled" => true,
                                                                            "storage" => "file_storage")
    expect(config.dig("exporters", "clickhouse", "retry_on_failure")).to include("enabled" => true)
  end

  # Docker writes attrs.OTEL_SERVICE_NAME into every line of a container that
  # logs with `env: OTEL_SERVICE_NAME` (RUNBOOK "Logs and retention").
  it "names logs after the writing service and drops every other container's lines" do
    expect(operators).to include(include("type" => "filter", "expr" => "attributes.attrs?.OTEL_SERVICE_NAME == nil"))
    expect(operators).to include(include("type" => "move", "from" => "attributes.attrs.OTEL_SERVICE_NAME",
                                         "to" => 'resource["service.name"]'))
  end

  # Request and job lines carry "kind"; every other structured line (psp_call,
  # webhook.*, settlement.*, …) carries "event", sometimes with its own "kind".
  # No filter may pick lines by those fields, or some never reach the archive.
  it "keeps every PayHub JSON line, whatever its kind or event" do
    exprs = operators.filter_map { |op| op["expr"] if op["type"] == "filter" }
    expect(exprs.grep(/attributes\.(kind|event)/)).to be_empty
    # Event lines have no "time": they keep the timestamp Docker gave the line.
    expect(operators.select { |op| op["type"] == "time_parser" })
      .to contain_exactly(include("if" => "attributes.kind != nil and attributes.time != nil",
                                  "layout" => "2006-01-02T15:04:05.999999999Z07:00"))
  end

  it "recognises production's Logger::Formatter lines and keeps only those ending in JSON" do
    keep = ruby_regex(operators.find { |op| op["type"] == "filter" && op["expr"].include?("matches") }["expr"]
                        .then { |expr| expr[/matches "(.*)"\)\z/, 1].gsub("\\\\", "\\") })
    parse = ruby_regex(operators.find { |op| op["type"] == "regex_parser" && op["regex"].include?("json") }["regex"])
    request = 'I, [2026-10-21T08:02:17.059123 #1]  INFO -- : [req-1] {"kind":"request","status":201}'
    event = 'E, [2026-10-21T08:02:20.200000 #1] ERROR -- : [req-2] {"event":"webhook.invalid_signature"}'
    job = 'I, [2026-10-21T08:02:18.000000 #1]  INFO -- : [ActiveJob] [CaptureJob] [j1] {"kind":"job"}'
    plain = "I, [2026-10-21T08:02:21.000000 #1]  INFO -- : [req-2] Completed 401 Unauthorized in 3ms"

    expect([request, event, job, plain].map { |line| keep.match?(line) }).to eq([true, true, true, false])
    expect([request, event, job].map { |line| parse.match(line).values_at(:level, :json) })
      .to eq([["I", '{"kind":"request","status":201}'], ["E", '{"event":"webhook.invalid_signature"}'],
              ["I", '{"kind":"job"}']])
  end

  it "keeps 90 days in ClickHouse and archives logs to S3 by the hour" do
    expect(config.dig("exporters", "clickhouse", "ttl")).to eq("2160h")
    expect(config.dig("exporters", "awss3", "s3uploader")).to include("s3_prefix" => "payhub/logs",
                                                                      "s3_partition" => "hour")
    expect(config.dig("service", "pipelines", "logs", "exporters")).to include("clickhouse", "awss3")
  end

  it "takes every endpoint and credential from the environment" do
    clickhouse = config.dig("exporters", "clickhouse")
    expect(clickhouse.values_at("endpoint", "username", "password")).to all(start_with("${env:"))
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
