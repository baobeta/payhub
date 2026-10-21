# frozen_string_literal: true

require "rails_helper"

# Grafana provisions these on boot (observability/grafana/provisioning/alerting).
# A rule that names a metric nobody emits, or reads the wrong service's copy of
# it, never fires and never errors either: the page just never comes. Pin the
# rule set, what each rule reads, and where it sends the page.
RSpec.describe "Grafana alert rules" do # rubocop:disable RSpec/DescribeClass
  let(:dir) { Rails.root.join("observability/grafana/provisioning/alerting") }
  let(:rules_file) { dir.join("payhub-rules.yaml") }
  let(:rules) do
    YAML.safe_load_file(rules_file)["groups"].flat_map { |group| group["rules"] }.index_by { |rule| rule["uid"] }
  end
  let(:contact) { YAML.safe_load_file(dir.join("contact-points.yaml")) }
  let(:runbook) { Rails.root.join("RUNBOOK.md").read }

  # uid => [severity, the metric (or table) its query must read]
  let(:expected) do
    {
      "payhub-late-success" => ["page", "MetricName = 'payhub_late_success_total'"],
      "payhub-psp-never-received" => ["ticket", "MetricName = 'payhub_psp_never_received_total'"],
      "payhub-audit-write-failed" => ["page", "MetricName = 'payhub_audit_write_failed_total'"],
      "payhub-psp-call-in-tx" => ["ticket", "MetricName = 'payhub_psp_call_in_transaction_total'"],
      "payhub-circuit-open" => ["page", "MetricName = 'payhub_psp_circuit_opened_total'"],
      "payhub-recon-breaks" => ["ticket", "MetricName = 'payhub_settlement_discrepancies_total'"],
      "payhub-ledger-imbalance" => ["page", "MetricName = 'payhub_ledger_imbalance_detected_total'"],
      "payhub-stuck-alerts" => ["page", "MetricName = 'payhub_stuck_payment_alerts_total'"],
      "payhub-stuck-unknown" => ["page", "MetricName = 'payhub_unknown_state_payments'"],
      "payhub-dead-letters" => ["ticket", "MetricName = 'payhub_outbound_events_dead'"],
      "payhub-error-spans" => ["page", "FROM otel.otel_traces"],
      "payhub-slo-api-p95" => ["ticket", "FROM otel.otel_traces"],
      "payhub-slo-outcome" => ["page", "MetricName = 'payhub_unknown_state_payments'"],
      "payhub-scrape-down" => ["page", "MetricName = 'up'"],
      "payhub-logs-silent" => ["page", "FROM otel.otel_logs"],
      "payhub-archive-upload-failed" => ["page", "MetricName = 'otelcol_exporter_send_failed_log_records'"]
    }
  end

  let(:known_metrics) do
    Metrics::COUNTERS.keys.map { |name| "payhub_#{name}_total" } + Metrics::GAUGES.keys.map { |name| "payhub_#{name}" }
  end

  def query(rule, ref_id)
    rule["data"].find { |step| step["refId"] == ref_id }
  end

  def sql(uid)
    query(rules.fetch(uid), "A").dig("model", "rawSql")
  end

  def metrics_in(text)
    text.scan(/MetricName = '(payhub_\w+)'/).flatten
  end

  it "provisions every alert, each reading the metric it is about" do
    expect(rules.keys).to match_array(expected.keys)
    expected.each { |uid, (_, read)| expect(sql(uid)).to include(read), uid }
  end

  it "names only metrics the app emits (Metrics::COUNTERS and GAUGES)" do
    named = rules.keys.flat_map { |uid| metrics_in(sql(uid)) }.uniq
    expect(named.size).to be >= 9
    expect(named - known_metrics).to be_empty
  end

  # Web refreshes the DB-backed gauges on every scrape; the worker only when
  # its sweeper or delivery job runs, so its copy can be stale.
  it "reads the DB-backed gauges from web only" do
    gauges = Metrics::GAUGES.keys.map { |name| "payhub_#{name}" }
    gauge_rules = rules.keys.select { |uid| metrics_in(sql(uid)).intersect?(gauges) }
    expect(gauge_rules).to include("payhub-stuck-unknown", "payhub-dead-letters", "payhub-slo-outcome")
    expect(gauge_rules.map { |uid| sql(uid) }).to all(include("ServiceName = 'payhub-web'"))
  end

  # Each scrape job reports its own cumulative series; a max(Value) across
  # them compares two unrelated counters. A series that first appears inside
  # the window (the first increment since a restart) is an increase from zero,
  # which max(Value) - min(Value) reads as 0. And ClickHouse compares maps by
  # key order, which differs between rows of one series: mapSort first.
  it "counts counter increases per series, from zero for a new one, never across services" do
    counters = Metrics::COUNTERS.keys.map { |name| "payhub_#{name}_total" }
    counter_sqls = rules.keys.filter_map { |uid| sql(uid) if metrics_in(sql(uid)).intersect?(counters) }
    expect(counter_sqls.size).to be >= 9
    expect(counter_sqls).to all(include("FROM otel.otel_metrics_sum"))
    expect(counter_sqls).to all(include("lagInFrame(Value, 1, 0) OVER (PARTITION BY ServiceName, mapSort(Attributes), " \
                                        "mapSort(ResourceAttributes) ORDER BY TimeUnix"))
    expect(counter_sqls).to all(match(/ServiceName (= 'payhub-worker'|IN \('payhub-web', 'payhub-worker'\))/))
    expect(counter_sqls.join).not_to match(/max\(Value\)\s*-\s*min\(Value\)/)
  end

  it "reads job-only counters from the worker" do
    %w[payhub-late-success payhub-recon-breaks payhub-ledger-imbalance payhub-stuck-alerts].each do |uid|
      expect(sql(uid)).to include("ServiceName = 'payhub-worker'"), uid
    end
  end

  it "measures errors and latency from server spans in otel_traces" do
    expect(sql("payhub-error-spans")).to include("StatusCode = 'Error'", "SpanKind IN ('Server', 'Consumer')")
    expect(sql("payhub-slo-api-p95")).to include("quantile(0.95)(Duration)", "SpanKind = 'Server'",
                                                 "SpanAttributes['http.route'] LIKE '/v1/%'")
  end

  it "pages on a failed scrape per service, silent logs, and failed archive uploads" do
    expect(sql("payhub-scrape-down")).to include("FROM otel.otel_metrics_gauge", "'payhub-web', 'payhub-worker'")
    expect(sql("payhub-logs-silent")).to include("ServiceName LIKE 'payhub%'")
    expect(sql("payhub-archive-upload-failed")).to include("ServiceName = 'otelcol'",
                                                           "Attributes['exporter'] = 'awss3'")
    production = YAML.safe_load_file(Rails.root.join("observability/otel-collector.production.yaml"))
    expect(production.dig("service", "pipelines", "logs", "exporters")).to include("awss3")
    expect(production.dig("receivers", "prometheus", "config", "scrape_configs").pluck("job_name")).to include("otelcol")
  end

  it "builds every rule as ClickHouse query, reduce last, threshold, at the right severity" do
    rules.each do |uid, rule|
      expect(query(rule, "A")).to include("datasourceUid" => "clickhouse"), uid
      expect(query(rule, "B")["model"]).to include("type" => "reduce", "reducer" => "last", "expression" => "A"), uid
      expect(query(rule, "C")["model"]).to include("type" => "threshold", "expression" => "B"), uid
      expect(rule).to include("condition" => "C"), uid
      expect(rule.dig("labels", "severity")).to eq(expected.dig(uid, 0)), uid
    end
  end

  it "sends every rule to payhub-oncall with a summary and its RUNBOOK section" do
    anchors = runbook.scan(%r{<a id="([^"]+)"></a>}).flatten
    rules.each do |uid, rule|
      expect(rule.dig("notification_settings", "receiver")).to eq("payhub-oncall"), uid
      expect(rule.dig("annotations", "summary")).to be_present, uid
      anchor = rule.dig("annotations", "runbook_url")[/RUNBOOK\.md#(.+)\z/, 1]
      expect(anchors).to include(anchor), uid
    end
  end

  # Grafana expands $VAR in every provisioning file: a "$" in SQL would be
  # replaced (usually by nothing) before the rule is loaded.
  it "contains no $ for Grafana to expand" do
    expect(rules_file.read).not_to include("$")
  end

  it "delivers to a webhook whose URL comes from ALERT_WEBHOOK_URL, never a literal" do
    receiver = contact["contactPoints"].find { |point| point["name"] == "payhub-oncall" }["receivers"].sole
    expect(receiver).to include("type" => "webhook")
    expect(receiver.dig("settings", "url")).to eq("${ALERT_WEBHOOK_URL}")
    expect(contact["policies"].sole).to include("receiver" => "payhub-oncall", "group_by" => ["alertname"],
                                                "repeat_interval" => "4h")
    compose = YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true)
    expect(compose.dig("services", "grafana", "environment", "ALERT_WEBHOOK_URL")).to start_with("${ALERT_WEBHOOK_URL")
  end
end
