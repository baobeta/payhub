# frozen_string_literal: true

require "rails_helper"

# The dev collector (observability/otel-collector.yaml) must scrape web and
# worker separately and send the same bearer token /metrics checks
# (MetricsAuth). A drifted target or a dropped token only shows up as an
# empty Grafana panel, so pin them here.
RSpec.describe "OpenTelemetry collector config" do # rubocop:disable RSpec/DescribeClass
  let(:config) { YAML.safe_load_file(Rails.root.join("observability/otel-collector.yaml")) }
  let(:jobs) do
    config.dig("receivers", "prometheus", "config", "scrape_configs").index_by { |job| job["job_name"] }
  end

  it "scrapes web and worker as separate jobs" do
    targets = jobs.transform_values { |job| job["static_configs"].flat_map { |static| static["targets"] } }
    expect(targets).to eq("payhub-web" => ["web:3000"], "payhub-worker" => ["worker:9394"])
  end

  it "sends METRICS_TOKEN as the bearer credentials on every scrape" do
    expect(jobs.values).to all(include("metrics_path" => "/metrics",
                                       "authorization" => { "credentials" => "${env:METRICS_TOKEN}" }))
  end

  it "passes METRICS_TOKEN to the collector and the app from the same variable" do
    compose = YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true)
    env = %w[otel-collector web worker].map { |service| compose.dig("services", service, "environment", "METRICS_TOKEN") }
    expect(env).to eq(["${METRICS_TOKEN:-}"] * 3)
  end
end
