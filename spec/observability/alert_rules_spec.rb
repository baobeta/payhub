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

  # uid => [severity, what its query must read, evaluator, threshold, for, window in seconds]
  let(:expected) do
    {
      "payhub-late-success" => ["page", "MetricName = 'payhub_late_success_total'", "gt", 0, "1m", 600],
      "payhub-psp-never-received" => ["ticket", "MetricName = 'payhub_psp_never_received_total'", "gt", 0, "1m", 900],
      "payhub-audit-write-failed" => ["page", "MetricName = 'payhub_audit_write_failed_total'", "gt", 0, "1m", 600],
      "payhub-psp-call-in-tx" => ["ticket", "MetricName = 'payhub_psp_call_in_transaction_total'", "gt", 0, "1m", 3600],
      "payhub-circuit-open" => ["page", "MetricName = 'payhub_psp_circuit_opened_total'", "gt", 0, "1m", 300],
      "payhub-recon-breaks" => ["ticket", "MetricName = 'payhub_settlement_discrepancies_total'", "gt", 0, "1m", 86_400],
      "payhub-ledger-imbalance" => ["page", "MetricName = 'payhub_ledger_imbalance_detected_total'", "gt", 0, "1m", 86_400],
      "payhub-stuck-alerts" => ["page", "MetricName = 'payhub_stuck_payment_alerts_total'", "gt", 0, "1m", 900],
      "payhub-stuck-unknown" => ["page", "MetricName = 'payhub_unknown_state_payments'", "gt", 0, "15m", 300],
      "payhub-dead-letters" => ["ticket", "MetricName = 'payhub_outbound_events_dead'", "gt", 0, "0s", 300],
      "payhub-error-spans" => ["page", "FROM otel.otel_traces", "gt", 2, "5m", 300],
      "payhub-slo-api-p95" => ["ticket", "FROM otel.otel_traces", "gt", 300, "10m", 600],
      "payhub-slo-outcome" => ["page", "MetricName = 'payhub_unknown_state_payments'", "gt", 0, "0s", 3600],
      "payhub-scrape-down" => ["page", "MetricName = 'up'", "lt", 1, "5m", 60],
      "payhub-logs-silent" => ["page", "FROM otel.otel_logs", "lt", 1, "1m", 900],
      "payhub-archive-upload-failed" => ["page", "MetricName = 'otelcol_exporter_send_failed_log_records'",
                                         "gt", 0, "1m", 3600]
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

  # Every rule over otel_metrics_sum: the app's counters and the collector's.
  def counter_uids
    rules.keys.select { |uid| sql(uid).include?("FROM otel.otel_metrics_sum") }
  end

  # The window the query reads, not the extra day of lookback before it.
  def window_seconds(text)
    text.scan(/now\(\) - INTERVAL (\d+) (MINUTE|HOUR)(?! - INTERVAL 1 DAY)/)
        .map { |n, unit| n.to_i * (unit == "HOUR" ? 3600 : 60) }.max
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
    expect(gauge_rules).to contain_exactly("payhub-stuck-unknown", "payhub-dead-letters", "payhub-slo-outcome")
    expect(gauge_rules.map { |uid| sql(uid) }).to all(include("ServiceName = 'payhub-web'"))
  end

  # Each scrape job reports its own cumulative series; a max(Value) across
  # them compares two unrelated counters. A series that first appears inside
  # the window (the first increment since a restart) is an increase from zero,
  # which max(Value) - min(Value) reads as 0. And ClickHouse compares maps by
  # key order, which differs between rows of one series: mapSort first.
  it "counts counter increases per series, never across services" do
    expect(counter_uids.size).to eq(9)
    counter_sqls = counter_uids.map { |uid| sql(uid) }
    expect(counter_sqls).to all(include("lagInFrame(Value, 1, nan) OVER (PARTITION BY ServiceName, mapSort(Attributes), " \
                                        "mapSort(ResourceAttributes) ORDER BY TimeUnix"))
    expect(counter_sqls).to all(include("if(c.Value >= c.prev, c.Value - c.prev, c.Value)"))
    expect(counter_sqls).to all(match(/ServiceName (= 'payhub-worker'|= 'otelcol'|IN \('payhub-web', 'payhub-worker'\))/))
    expect(counter_sqls.join).not_to match(/max\(Value\)\s*-\s*min\(Value\)/)
  end

  # A series' first sample counts in full only if the collector was already
  # scraping that instance (an older `up`); on a cold start (first deploy, a
  # new ClickHouse volume, a long collector outage) every series appears with
  # `up` and its value is the baseline, or every counter would page at once.
  it "counts a series' first sample only when up for the same instance is at least 30s older" do
    counter_uids.each do |uid|
      expect(sql(uid)).to include("if(isNaN(c.prev),", "if(u.first_up <= c.TimeUnix - INTERVAL 30 SECOND, c.Value, 0)",
                                  "WHERE MetricName = 'up'",
                                  "ON c.ServiceName = u.ServiceName AND c.instance = u.instance"), uid
      expect(sql(uid).scan("ResourceAttributes['service.instance.id'] AS instance").size).to eq(2), uid
    end
  end

  # The `up` subquery is the counter subquery's twin: a different service or
  # lookback there and the gate judges first samples against the wrong `up`.
  it "reads up for the same services and lookback as each counter" do
    counter_uids.each do |uid|
      services = sql(uid).scan(/ServiceName (?:= '[^']+'|IN \('[^)]*\))/)
      lookbacks = sql(uid).scan(/now\(\) - INTERVAL \d+ (?:MINUTE|HOUR) - INTERVAL 1 DAY/)
      expect([services.size, services.uniq.size]).to eq([2, 1]), uid
      expect([lookbacks.size, lookbacks.uniq.size]).to eq([2, 1]), uid
    end
  end

  it "reads job-only counters from the worker" do
    %w[payhub-late-success payhub-recon-breaks payhub-ledger-imbalance payhub-stuck-alerts].each do |uid|
      expect(sql(uid)).to include("ServiceName = 'payhub-worker'"), uid
    end
  end

  it "measures errors and latency from server spans in otel_traces, with a minimum count" do
    expect(sql("payhub-error-spans")).to include("StatusCode = 'Error'", "SpanKind IN ('Server', 'Consumer')",
                                                 "NOT IN ('/metrics', '/healthz')", "if(count() < 20, 0,")
    expect(sql("payhub-slo-api-p95")).to include("quantile(0.95)(Duration)", "SpanKind = 'Server'",
                                                 "SpanAttributes['http.route'] LIKE '/v1/%'")
    expect(sql("payhub-slo-outcome")).not_to include("stuck_payment_alerts") # payhub-stuck-alerts pages for those
  end

  it "pages on a failed scrape per service, silent logs, and failed archive uploads" do
    expect(sql("payhub-scrape-down")).to include("FROM otel.otel_metrics_gauge", "'payhub-web', 'payhub-worker'")
    # TimestampTime is otel_logs' partition and primary key; Timestamp is not.
    expect(sql("payhub-logs-silent")).to include("ServiceName LIKE 'payhub%'",
                                                 "TimestampTime >= now() - INTERVAL 15 MINUTE")
    expect(sql("payhub-archive-upload-failed")).to include("ServiceName = 'otelcol'",
                                                           "Attributes['exporter'] = 'awss3'")
    production = YAML.safe_load_file(Rails.root.join("observability/otel-collector.production.yaml"))
    expect(production.dig("service", "pipelines", "logs", "exporters")).to include("awss3")
    expect(production.dig("receivers", "prometheus", "config", "scrape_configs").pluck("job_name")).to include("otelcol")
  end

  it "builds every rule as ClickHouse query, reduce last, threshold" do
    rules.each do |uid, rule|
      expect(query(rule, "A")).to include("datasourceUid" => "clickhouse"), uid
      expect(query(rule, "B")["model"]).to include("type" => "reduce", "reducer" => "last", "expression" => "A"), uid
      expect(query(rule, "C")["model"]).to include("type" => "threshold", "expression" => "B"), uid
      expect(rule).to include("condition" => "C"), uid
    end
  end

  it "fires at the pinned threshold, after the pinned wait, over the window its SQL reads" do
    rules.each do |uid, rule|
      _, _, type, threshold, wait, window = expected.fetch(uid)
      expect(query(rule, "C").dig("model", "conditions").sole["evaluator"]).to eq("type" => type, "params" => [threshold]), uid
      expect(rule["for"]).to eq(wait), uid
      expect(query(rule, "A").dig("relativeTimeRange", "from")).to eq(window), uid
      expect(window_seconds(sql(uid))).to eq(window), uid
    end
  end

  # Counters wait a minute so one odd sample does not page. A query error
  # (ClickHouse unreachable) fires DatasourceError; no rows is OK, except where
  # no rows is itself the incident.
  it "pins the error and no-data states of every rule" do
    rules.each do |uid, rule|
      no_data = %w[payhub-scrape-down payhub-logs-silent].include?(uid) ? "Alerting" : "OK"
      expect(rule).to include("execErrState" => "Error", "noDataState" => no_data), uid
    end
  end

  it "pages on page and tickets on ticket, with a summary showing the value and its RUNBOOK section" do
    anchors = runbook.scan(%r{<a id="([^"]+)"></a>}).flatten
    rules.each do |uid, rule|
      severity = rule.dig("labels", "severity")
      expect(severity).to eq(expected.dig(uid, 0)), uid
      expect(rule.dig("notification_settings", "receiver"))
        .to eq({ "page" => "payhub-oncall", "ticket" => "payhub-tickets" }.fetch(severity)), uid
      expect(rule.dig("annotations", "summary")).to include('{{ index .Values "B" }}'), uid
      expect(anchors).to include(rule.dig("annotations", "runbook_url")[/RUNBOOK\.md#(.+)\z/, 1]), uid
    end
    expect(anchors).to include("datasource-error")
  end

  # Grafana expands $VAR in every provisioning file: a "$" in SQL would be
  # replaced (usually by nothing) before the rule is loaded.
  it "contains no $ for Grafana to expand" do
    expect(rules_file.read).not_to include("$")
  end

  describe "docs/SLO.md and the dashboard's SLOs row" do
    # The uids in the last column of docs/SLO.md's summary table (the one headed "| SLO |").
    def slo_alert_uids
      lines = Rails.root.join("docs/SLO.md").readlines
      table = lines.drop_while { |line| !line.start_with?("| SLO |") }.take_while { |line| line.start_with?("|") }
      table.drop(2).flat_map { |row| row.split("|")[-2].scan(/`(payhub-[a-z0-9-]+)`/) }.flatten.uniq
    end

    # The stat panels after the "SLOs" row, by the alert each names in its description.
    def slo_panels
      panels = JSON.parse(Rails.root.join("observability/grafana/dashboards/payhub.json").read)["panels"]
      row = panels.find { |panel| panel["type"] == "row" && panel["title"] == "SLOs" }
      panels.select { |panel| panel["type"] == "stat" && panel.dig("gridPos", "y") > row.dig("gridPos", "y") }
            .index_by { |panel| panel["description"][/`(payhub-[a-z0-9-]+)`/, 1] }
    end

    it "names only provisioned alerts, and every SLO alert (payhub-slo-*)" do
      expect(slo_alert_uids.size).to be >= 10
      expect(slo_alert_uids - rules.keys).to be_empty
      slo_rules = rules.keys.grep(/\Apayhub-slo-/)
      expect(slo_rules).not_to be_empty
      expect(slo_alert_uids).to include(*slo_rules)
    end

    it "gives each of its alerts' severity and for" do
      doc = Rails.root.join("docs/SLO.md").read
      slo_alert_uids.each do |uid|
        rule = rules.fetch(uid)
        expect(doc).to include("`#{uid}` (#{rule.dig('labels', 'severity')}, `for: #{rule['for']}`)"), uid
      end
    end

    it "shows each SLO alert's current value on the dashboard, from the alert's own SQL" do
      expect(slo_panels.keys).to match_array(slo_alert_uids)
      slo_panels.each do |uid, panel|
        expect(panel["targets"].sole["rawSql"]).to eq(sql(uid)), uid
        expect(panel.dig("datasource", "uid")).to eq("clickhouse"), uid
      end
    end

    # Grafana colours a value by the highest step at or below it. An "above T"
    # count turns red at T + 1, so a quiet 0 stays green; p95 (ms, continuous)
    # at T, which differs from "above" only at exactly T. A "below T" rule is
    # red until T.
    it "turns each panel red where its alert's condition starts, and states the alert's for" do
      slo_panels.each do |uid, panel|
        rule = rules.fetch(uid)
        evaluator = query(rule, "C").dig("model", "conditions").sole["evaluator"]
        threshold = evaluator["params"].sole
        red_from = panel.dig("fieldConfig", "defaults", "unit") == "ms" ? threshold : threshold + 1
        steps = panel.dig("fieldConfig", "defaults", "thresholds", "steps").map { |step| step.values_at("color", "value") }
        expect(steps).to eq(evaluator["type"] == "gt" ? [["green", nil], ["red", red_from]] : [["red", nil], ["green", threshold]]), uid
        expect(panel["description"]).to include("`for: #{rule['for']}`"), uid
      end
    end
  end

  it "delivers pages and tickets to webhooks whose URLs come from the environment, never a literal" do
    points = contact["contactPoints"].index_by { |point| point["name"] }.transform_values { |point| point["receivers"].sole }
    expect(points.keys).to contain_exactly("payhub-oncall", "payhub-tickets")
    expect(points.values).to all(include("type" => "webhook"))
    expect(points.transform_values { |receiver| receiver.dig("settings", "url") })
      .to eq("payhub-oncall" => "${ALERT_WEBHOOK_URL}", "payhub-tickets" => "${ALERT_TICKET_WEBHOOK_URL}")
    group_by = rules.values.map { |rule| rule.dig("notification_settings", "group_by") }.uniq.sole
    expect(contact["policies"].sole).to include("receiver" => "payhub-oncall", "group_by" => group_by,
                                                "repeat_interval" => "4h")
    env = YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true).dig("services", "grafana", "environment")
    expect(env.values_at("ALERT_WEBHOOK_URL", "ALERT_TICKET_WEBHOOK_URL")).to eq([
      "${ALERT_WEBHOOK_URL:-http://localhost:9/payhub-oncall}", "${ALERT_TICKET_WEBHOOK_URL:-http://localhost:9/payhub-tickets}"
    ])
  end
end
