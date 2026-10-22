# Production readiness: implementation plan

> **Note:** README.md and RUNBOOK.md describe what was actually built. Where this plan's sketches differ (e.g. `RAILS_SERVE_STATIC_FILES`, the roles SQL without `FOR ROLE`, the `puma.rb` `workers` lines), they are superseded.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Close every production-readiness gap found in the 2026-10-21 review. Code that can be fixed inside this repo gets test-first tasks. Choices that depend on outside parties get decision tasks with clear exit criteria.

**Architecture:**
- **Phase 1** closes two security gaps: the public demo is mounted in production, and the PSP keys fall back to test values. It also protects `/metrics`.
- **Phase 2** turns the existing OpenTelemetry → ClickHouse → Grafana stack into a production one:
  - metrics shared across processes, from web and worker
  - production log collection
  - retention that meets PCI DSS
  - provisioned alert rules and a contact point
  - written SLOs
- **Phase 3** hardens how the app ships: a production image, Puma workers, migration safety, least-privilege database roles, faster CI and a dependency backlog.
- **Phase 4** covers the decisions the code can't make: the real PSP, card tokenization, 3DS, disputes, hosting, backups, PCI and onboarding.

**Tech stack:**
- Rails 8 API with Sorbet, Sidekiq 7 with `sidekiq-cron` (backed by Redis), PostgreSQL 16
- `prometheus-client` 5.x, lograge JSON logs
- OpenTelemetry Collector contrib 0.111.0, ClickHouse, Grafana 11.2 with the ClickHouse datasource plugin
- Vue 3 and Vite, Docker Compose, GitHub Actions

---

## Conventions for every code task

- **Branch:** work on `chore/production-readiness`, created from `master`.
- **Test database:** use your own.
  ```bash
  RAILS_ENV=test TEST_DATABASE=payhub_test_prod bin/rails db:create db:schema:load
  ```
  Prefix every command with `TEST_DATABASE=payhub_test_prod`. Postgres listens on 5434 and Redis on 6379 (now 6380 on the host, see README); start them with `docker compose up -d db redis`.
- **Run one spec:**
  ```bash
  COVERAGE=false TEST_DATABASE=payhub_test_prod bundle exec rspec <file> -e "<name>"
  ```
- **Run all checks before each commit:**
  ```bash
  TEST_DATABASE=payhub_test_prod bundle exec rspec          # expect 0 failures
  bundle exec srb tc --ignore=.claude                       # expect "No errors!"
  bundle exec rubocop                                       # expect no offenses
  ```
- **Spec names start with a PR id**, `PR-<n>`. Example: `it "PR-1: the demo API is not routed in production"`.
- **Commit messages** are short and imperative, matching the existing history. Comments cite DECISIONS and RUNBOOK entries as the codebase already does.
- **New config switches** are environment variables. Each one goes in the README's "Configuration" section and the RUNBOOK's quick reference.

---

# Phase 1: close the security gaps

## Task 1: the public demo is off in production unless turned on

The demo (`/demo/api/*` and `/demo/*`) needs no login. It can create payments, run chaos runs against a PSP and reset data, and right now it is routed in every environment. It must not be reachable in production unless someone turns it on on purpose, for example on a dedicated demo host.

**Files:**
- Modify: `config/application.rb` (add `config.x.demo_enabled`)
- Modify: `config/routes.rb:142-159` (add a request-time constraint to the demo namespace and the demo shell route)
- Test: `spec/requests/demo/demo_gate_spec.rb` (create)

**Step 1: Write the failing test**

```ruby
# spec/requests/demo/demo_gate_spec.rb
require "rails_helper"

RSpec.describe "Demo gate", type: :request do
  around do |example|
    previous = Rails.configuration.x.demo_enabled
    example.run
  ensure
    Rails.configuration.x.demo_enabled = previous
  end

  it "PR-1: the demo API and shell answer 404 when the demo is disabled" do
    Rails.configuration.x.demo_enabled = false

    get "/demo/api/ledger_summary"
    expect(response).to have_http_status(:not_found)
    post "/demo/api/reset"
    expect(response).to have_http_status(:not_found)
    get "/demo"
    expect(response).to have_http_status(:not_found)
  end

  it "PR-1: the demo works when enabled" do
    Rails.configuration.x.demo_enabled = true

    get "/demo/api/ledger_summary"
    expect(response).to have_http_status(:ok)
  end

  it "PR-1: production defaults to disabled, everything else to enabled" do
    expect(PayhubConfig.demo_enabled_default("production", nil)).to be(false)
    expect(PayhubConfig.demo_enabled_default("production", "true")).to be(true)
    expect(PayhubConfig.demo_enabled_default("development", nil)).to be(true)
    expect(PayhubConfig.demo_enabled_default("test", nil)).to be(true)
  end
end
```

**Step 2: Run it.** Expected: FAIL. The disabled case returns 200, and `PayhubConfig` is undefined.

**Step 3: Implement**

```ruby
# app/lib/payhub_config.rb
# typed: strict
# frozen_string_literal: true

# Defaults for environment switches that must be safe in production.
module PayhubConfig
  extend T::Sig

  # The public demo needs no login (README "Dashboards"). In production it is
  # off unless DEMO_ENABLED=true is set on purpose, e.g. on a demo-only host.
  sig { params(rails_env: String, flag: T.nilable(String)).returns(T::Boolean) }
  def self.demo_enabled_default(rails_env, flag)
    return flag == "true" unless flag.nil?

    rails_env != "production"
  end
end
```

```ruby
# config/application.rb, inside class Application
config.x.demo_enabled = ENV["DEMO_ENABLED"].then do |flag|
  flag.nil? ? !Rails.env.production? : flag == "true"
end
```

`config/application.rb` loads before the autoloader, so it can't call `PayhubConfig` there. The same rule appears in both places, and `PayhubConfig` is the copy the spec tests.

```ruby
# config/routes.rb: wrap BOTH the `namespace :demo do … end` block and the
# `get "demo(/*path)"` shell route.
demo_enabled = ->(_request) { Rails.configuration.x.demo_enabled }
constraints(demo_enabled) do
  namespace :demo do
    # …unchanged…
  end
end
# …and at the bottom:
constraints(demo_enabled) do
  get "demo(/*path)", to: "demo/shell#show", format: false
end
```

**Step 4: Run the spec, then `spec/requests/demo` and `spec/routing`.** Expected: PASS. The route-permission inventory still lists the demo routes; they are only constrained.

**Step 5:**
- In `README.md`, under "Configuration", add a `DEMO_ENABLED` row that says the default is off in production.
- Commit with the message `"Turn the public demo off in production unless DEMO_ENABLED=true"`.

## Task 2: PSP credentials fail closed in production

The adapters use `ENV.fetch("NORDPAY_API_KEY", "np_test_key")` and similar calls, so a production deploy that forgets a variable quietly talks to the PSP with a test key. `AR_ENCRYPTION_*` already raises in production in this situation; the PSP credentials should behave the same way.

**Files:**
- Create: `app/lib/psp_env.rb`
- Modify: `app/adapters/nordpay_adapter.rb:16-19` and `app/adapters/kiripay_adapter.rb:16-19` (the `initialize` defaults)
- Modify: `app/lib/webhook_signature.rb`, method `secrets_from_env` (its fallback secret)
- Test: `spec/lib/psp_env_spec.rb`

**Step 1: Failing test**

```ruby
# spec/lib/psp_env_spec.rb
require "rails_helper"

RSpec.describe PspEnv do
  it "PR-2: outside production a missing variable falls back to the simulator default" do
    expect(described_class.fetch("PAYHUB_TEST_MISSING_VAR", "np_test_key")).to eq("np_test_key")
  end

  it "PR-2: in production a missing variable raises and names it" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect { described_class.fetch("PAYHUB_TEST_MISSING_VAR", "np_test_key") }
      .to raise_error(PspEnv::Missing, /PAYHUB_TEST_MISSING_VAR/)
  end

  it "PR-2: in production a simulator default value is refused even when set" do
    allow(Rails.env).to receive(:production?).and_return(true)
    stub_const("ENV", ENV.to_h.merge("PAYHUB_TEST_VAR" => "np_test_key"))
    expect { described_class.fetch("PAYHUB_TEST_VAR", "np_test_key") }.to raise_error(PspEnv::Missing, /test value/)
  end
end
```

**Step 2: Run it.** Expected: FAIL with `uninitialized constant PspEnv`.

**Step 3: Implement**

```ruby
# app/lib/psp_env.rb
# typed: strict
# frozen_string_literal: true

# PSP endpoints, keys and webhook secrets. Development and test talk to the
# simulators with their well-known defaults; production must be told every
# value, and is never allowed to run on a simulator default.
module PspEnv
  extend T::Sig

  class Missing < StandardError; end

  sig { params(name: String, simulator_default: String).returns(String) }
  def self.fetch(name, simulator_default)
    value = ENV[name]
    return value || simulator_default unless Rails.env.production?
    raise Missing, "Set #{name} for production (no simulator fallback)" if value.blank?
    raise Missing, "#{name} is set to the simulator's test value" if value == simulator_default

    value
  end
end
```

In both adapters, swap the defaults:

```ruby
def initialize(base_url: PspEnv.fetch("NORDPAY_URL", "http://localhost:4001"),
               api_key: PspEnv.fetch("NORDPAY_API_KEY", "np_test_key"),
               webhook_secrets: WebhookSignature.secrets_from_env("NORDPAY_WEBHOOK_SECRETS", "NORDPAY_WEBHOOK_SECRET", "np_whsec_test"))
```

Kiripay gets the same change with its own names. Inside `WebhookSignature.secrets_from_env`, use `PspEnv.fetch(single_var, default)` wherever it currently falls back to the default.

**Step 4: Check that adapters are built per call, not at boot.** If one is built at boot, a production boot raises, which is the behaviour we want. Run `grep -rn "Adapter.new" app config`. Then run the adapter specs, `psp_env_spec` and the full suite. Expected: PASS.

**Step 5:**
- Document the variables in the README and RUNBOOK.
- Commit with the message `"Refuse to run production on missing or simulator PSP credentials"`.

## Task 3: `/metrics` needs a bearer token when one is set (and always in production)

**Files:**
- Modify: `app/controllers/metrics_controller.rb`
- Test: `spec/requests/observability_spec.rb` (add examples)

**Step 1: Failing tests**

```ruby
describe "PR-3 /metrics protection" do
  around do |ex|
    old = ENV["METRICS_TOKEN"]
    ex.run
  ensure
    ENV["METRICS_TOKEN"] = old
  end

  it "PR-3: with METRICS_TOKEN set, a scrape without the token is 401" do
    ENV["METRICS_TOKEN"] = "s3cret"
    get "/metrics"
    expect(response).to have_http_status(:unauthorized)
  end

  it "PR-3: with the right bearer token the scrape works" do
    ENV["METRICS_TOKEN"] = "s3cret"
    get "/metrics", headers: { "Authorization" => "Bearer s3cret" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("payhub_")
  end

  it "PR-3: in production, an unset METRICS_TOKEN refuses every scrape" do
    ENV.delete("METRICS_TOKEN")
    allow(Rails.env).to receive(:production?).and_return(true)
    get "/metrics"
    expect(response).to have_http_status(:unauthorized)
  end
end
```

**Step 2: Run it.** Expected: FAIL, because every request gets 200.

**Step 3: Implement.** Add this at the top of `MetricsController`:

```ruby
before_action :require_scrape_token

private

# Scrapers present `Authorization: Bearer $METRICS_TOKEN`. Production with no
# token configured is closed, not open: an exposed /metrics leaks volumes.
sig { void }
def require_scrape_token
  expected = ENV["METRICS_TOKEN"].to_s
  return if expected.empty? && !Rails.env.production?

  given = request.authorization.to_s.delete_prefix("Bearer ")
  head :unauthorized unless expected.present? && ActiveSupport::SecurityUtils.secure_compare(given, expected)
end
```

`/healthz` stays open; it only reports whether the app is up.

**Step 4: Run it.** Expected: PASS. **Step 5:** commit with the message `"Require a bearer token to scrape /metrics"`. Task 7 adds the token to the collector's scrape config.

---

# Phase 2: production observability on the stack we already have

## Task 4: share metrics across processes

Today `prometheus-client` uses its default in-memory store. With Puma workers each process keeps its own counts, and a restart wipes them. The dashboard even says the counters reset "when web restarts". `DirectFileStore` keeps every process's values in files under one directory and adds them up when scraped.

**Files:**
- Create: `config/initializers/prometheus.rb`
- Modify: `app/lib/metrics.rb`. Gauges need `store_settings: { aggregation: :most_recent }`. Summing a "current value" across processes would be wrong, and so would `:max`: `/metrics` sets the gauges from the database only in the Puma worker that answers, so a max would keep another worker's stale higher value until every worker had been scraped again. (Implemented with `:most_recent`; the snippets below show the original `:max` draft.)
- Test: `spec/lib/metrics_spec.rb` (create)

**Step 1: Failing test**

```ruby
# spec/lib/metrics_spec.rb
require "rails_helper"

RSpec.describe Metrics do
  it "PR-4: the registry uses the file store when PROMETHEUS_MULTIPROC_DIR is set" do
    expect(Prometheus::Client.config.data_store).to be_a(Prometheus::Client::DataStores::DirectFileStore)
  end

  it "PR-4: gauges aggregate with max across processes" do
    Metrics.gauge(:unknown_state_payments, 3)
    gauge = Metrics::REGISTRY.get(:payhub_unknown_state_payments)
    expect(gauge.instance_variable_get(:@store_settings)).to include(aggregation: :max)
  end
end
```

For the test environment, set `ENV["PROMETHEUS_MULTIPROC_DIR"] ||= Rails.root.join("tmp/prometheus-test").to_s` at the top of `spec/rails_helper.rb`, before Rails boots. Then `rm -rf` that directory in a `before(:suite)` hook.

**Step 2: Run it.** Expected: FAIL, because the store is `Synchronized`.

**Step 3: Implement**

```ruby
# config/initializers/prometheus.rb
# frozen_string_literal: true

require "prometheus/client/data_stores/direct_file_store"

# Every process (each Puma worker, each Sidekiq process) writes its metrics to
# files in one directory; /metrics sums counters and takes the max of gauges.
# The directory must be wiped when the container starts (bin/docker-entrypoint).
if (dir = ENV["PROMETHEUS_MULTIPROC_DIR"].presence)
  FileUtils.mkdir_p(dir)
  Prometheus::Client.config.data_store = Prometheus::Client::DataStores::DirectFileStore.new(dir:)
end
```

In `Metrics.gauge`, create the gauge with
`REGISTRY.gauge(:"payhub_#{name}", docstring: …, labels: label_names, store_settings: { aggregation: :max })`.

**Step 4:**
- Run the spec and `spec/requests/observability_spec.rb`. Expected: PASS.
- Set `PROMETHEUS_MULTIPROC_DIR` in `docker-compose.yml`, one directory per service: `/rails/tmp/prometheus/web` in `&app_env`, overridden to `/rails/tmp/prometheus/worker` for the worker. One shared directory would break: web and worker share the bind mount, their PIDs overlap (each container counts from 1, and files are named by PID), web's start-time wipe would delete the worker's files, and once Tasks 5 and 6 scrape both, worker values would be counted twice.
- Wipe the directory at boot: `rm -rf "$PROMETHEUS_MULTIPROC_DIR"` in the compose `web` and `worker` commands, until `bin/docker-entrypoint` (Task 10) takes over.
- The test suite always uses its own `tmp/prometheus-test-<pid>` (never the caller's directory), wiped before boot and at exit.
- Production warns at boot when `WEB_CONCURRENCY` > 0 and `PROMETHEUS_MULTIPROC_DIR` is unset (`Metrics.warn_if_per_process_in_production`). The rules for production are in RUNBOOK, "Metrics across processes".

**Step 5:** commit with the message `"Share Prometheus metrics across processes with the file store"`.

## Task 5: the worker serves its own `/metrics`

Counters raised inside Sidekiq jobs never reach the web scrape when the web and worker run in separate containers. These include `late_success`, `psp_never_received`, `settlement_discrepancies`, `stuck_payment_alerts` and `psp_call_in_transaction`.

**Files:**
- Modify: `config/initializers/sidekiq.rb` (start a small exporter on server startup)
- Create: `app/lib/metrics_exporter.rb`
- Test: `spec/lib/metrics_exporter_spec.rb`

**Step 1: Failing test**

```ruby
require "rails_helper"
require "rack/mock"

RSpec.describe MetricsExporter do
  it "PR-5: serves the registry in Prometheus text format, guarded by the same token" do
    Metrics.increment(:late_success, psp: "kiripay")
    app = described_class.rack_app(token: "s3cret")

    denied = Rack::MockRequest.new(app).get("/metrics")
    expect(denied.status).to eq(401)

    ok = Rack::MockRequest.new(app).get("/metrics", "HTTP_AUTHORIZATION" => "Bearer s3cret")
    expect(ok.status).to eq(200)
    expect(ok.body).to include('payhub_late_success_total{psp="kiripay"}')
  end
end
```

**Step 2: Run it.** Expected: FAIL with `uninitialized constant MetricsExporter`.

**Step 3: Implement**

```ruby
# app/lib/metrics_exporter.rb
# typed: true
# frozen_string_literal: true

require "prometheus/client/formats/text"

# A tiny /metrics endpoint for processes that don't serve HTTP (Sidekiq).
# Same registry and token rule as MetricsController (PR-3).
module MetricsExporter
  def self.rack_app(token: ENV["METRICS_TOKEN"].to_s)
    lambda do |env|
      given = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      if token.empty? ? Rails.env.production? : !ActiveSupport::SecurityUtils.secure_compare(given, token)
        next [401, { "content-type" => "text/plain" }, ["unauthorized"]]
      end
      next [404, { "content-type" => "text/plain" }, ["not found"]] unless env["PATH_INFO"] == "/metrics"

      [200, { "content-type" => Prometheus::Client::Formats::Text::CONTENT_TYPE },
       [Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY)]]
    end
  end

  # Starts a WEBrick server on a background thread. Called from Sidekiq's startup hook.
  def self.start!(port: Integer(ENV.fetch("WORKER_METRICS_PORT", "9394")))
    require "rackup/handler/webrick"
    Thread.new do
      Rackup::Handler::WEBrick.run(rack_app, Host: "0.0.0.0", Port: port, AccessLog: [],
                                             Logger: WEBrick::Log.new(File::NULL))
    end
  end
end
```

Inside the `Sidekiq.configure_server` block in `config/initializers/sidekiq.rb`:

```ruby
config.on(:startup) { MetricsExporter.start! }
```

Add `webrick` and `rackup` to the Gemfile only if they aren't already resolvable; check with `bundle exec ruby -e 'require "rackup/handler/webrick"'`. Then run `bundle install` and commit `Gemfile.lock`.

**Step 4:**
- Run the spec. Expected: PASS.
- Manual check: `docker compose up -d worker`, then `curl -s localhost:9394/metrics | head` (temporarily map the port in compose) shows `payhub_` lines.

**Step 5:** commit with the message `"Serve worker metrics on :9394 so job counters reach the scrape"`.

## Task 6: the collector scrapes the worker and sends the token

**Files:**
- Modify: `observability/otel-collector.yaml`, receiver `prometheus.config.scrape_configs`
- Modify: `docker-compose.yml`. Give `otel-collector` the env var `METRICS_TOKEN: ${METRICS_TOKEN:-}` and give `&app_env` the same.

**Step 1: Change the config**

```yaml
  prometheus:
    config:
      scrape_configs:
        - job_name: payhub-web
          scrape_interval: 15s
          metrics_path: /metrics
          authorization: { credentials: "${env:METRICS_TOKEN}" }
          static_configs: [{ targets: ["web:3000"] }]
        - job_name: payhub-worker
          scrape_interval: 15s
          metrics_path: /metrics
          authorization: { credentials: "${env:METRICS_TOKEN}" }
          static_configs: [{ targets: ["worker:9394"] }]
```

**Step 2: Validate it**

```bash
docker compose run --rm otel-collector validate --config=/etc/otelcol/config.yaml
```

Expected: exit 0.

**Step 3: Check end to end**

1. Run `docker compose up -d`.
2. Trigger a job metric with `docker compose exec -T web bin/rails runner 'StuckPaymentSweeperJob.perform_now'`.
3. After 30 seconds, query ClickHouse:

```bash
curl 'localhost:8123/?user=otel&password=otel' -d "SELECT DISTINCT MetricName FROM otel.otel_metrics_gauge WHERE ResourceAttributes['service.name']='payhub-worker' OR Attributes['job']='payhub-worker' LIMIT 20"
```

Expected: `payhub_unknown_state_payments` appears for the worker job.

**Step 4:** commit with the message `"Scrape the worker's metrics and send the scrape token"`.

## Task 7: production collector config (stdout logs, retention, archive)

Production logs JSON to STDOUT (`config/environments/production.rb`). The current collector only tails `development.log`. Production needs container log collection, ClickHouse retention long enough to keep 3 months readily available, and an archive covering 12 months (PCI DSS 10.5.1).

**Files:**
- Create: `observability/otel-collector.production.yaml`
- Create: `spec/observability/collector_config_spec.rb`. It is a static check of both collector configs.
- Modify: `RUNBOOK.md`. Add a new section, "Logs and retention".

**Step 1: Failing test**

```ruby
# spec/observability/collector_config_spec.rb
require "rails_helper"

RSpec.describe "otel-collector production config" do
  let(:config) { YAML.load_file(Rails.root.join("observability/otel-collector.production.yaml")) }

  it "PR-7: reads container stdout logs, not development.log" do
    include_paths = config.dig("receivers", "filelog", "include")
    expect(include_paths).to include("/var/lib/docker/containers/*/*-json.log")
    expect(include_paths.join).not_to include("development.log")
  end

  it "PR-7: keeps at least 90 days in ClickHouse and archives logs for 13 months" do
    expect(config.dig("exporters", "clickhouse", "ttl")).to eq("2160h")
    expect(config.dig("exporters", "awss3", "s3uploader", "s3_prefix")).to eq("payhub/logs")
    expect(config.dig("service", "pipelines", "logs", "exporters")).to include("clickhouse", "awss3")
  end

  it "PR-7: takes ClickHouse credentials from the environment, never literals" do
    ch = config.dig("exporters", "clickhouse")
    expect(ch["password"]).to eq("${env:CLICKHOUSE_PASSWORD}")
    expect(ch["username"]).to eq("${env:CLICKHOUSE_USER}")
  end
end
```

**Step 2: Run it.** Expected: FAIL with ENOENT, because the file doesn't exist yet.

**Step 3: Create the config.** Copy the receivers, processors and pipeline layout from `observability/otel-collector.yaml`, then:

```yaml
receivers:
  otlp: { protocols: { http: { endpoint: 0.0.0.0:4318 }, grpc: { endpoint: 0.0.0.0:4317 } } }
  prometheus:
    config:
      scrape_configs:
        - job_name: payhub-web
          scrape_interval: 15s
          authorization: { credentials: "${env:METRICS_TOKEN}" }
          static_configs: [{ targets: ["${env:WEB_METRICS_TARGET}"] }]
        - job_name: payhub-worker
          scrape_interval: 15s
          authorization: { credentials: "${env:METRICS_TOKEN}" }
          static_configs: [{ targets: ["${env:WORKER_METRICS_TARGET}"] }]
  filelog:
    include: [/var/lib/docker/containers/*/*-json.log]
    start_at: end
    include_file_path: true
    operators:
      - type: container          # unwraps Docker's JSON envelope (stream, time, log)
        format: docker
      # From here, the same JSON parsing as the dev config: keep only lograge or
      # structured JSON lines, parse them, lift trace ids, and tag service.name.
      - type: filter
        expr: 'not (body matches "^(\\[[^\\]]*\\] )*\\{")'
      - type: regex_parser
        regex: '^(?:\[[^\]]*\] )*(?P<json>\{.*\})\s*$'
        parse_to: attributes
      - type: json_parser
        parse_from: attributes.json
        parse_to: attributes
      - type: remove
        field: attributes.json
      - type: trace_parser
        trace_id: { parse_from: attributes.trace_id }
        span_id: { parse_from: attributes.span_id }
      - type: add
        field: resource["service.name"]
        value: payhub
processors:
  memory_limiter: { check_interval: 1s, limit_mib: 800 }
  batch: { timeout: 5s }
exporters:
  clickhouse:
    endpoint: "${env:CLICKHOUSE_ENDPOINT}"
    database: otel
    username: "${env:CLICKHOUSE_USER}"
    password: "${env:CLICKHOUSE_PASSWORD}"
    create_schema: true
    ttl: 2160h                # 90 days queryable in Grafana (PCI DSS 10.5.1: 3 months immediately available)
    timeout: 10s
    retry_on_failure: { enabled: true }
  awss3:                      # 12-month archive. The bucket lifecycle rule (13 months) is set outside: see RUNBOOK.
    s3uploader:
      region: "${env:LOG_ARCHIVE_REGION}"
      s3_bucket: "${env:LOG_ARCHIVE_BUCKET}"
      s3_prefix: payhub/logs
      s3_partition_format: "year=%Y/month=%m/day=%d/hour=%H"
    marshaler: otlp_json
service:
  pipelines:
    traces:  { receivers: [otlp], processors: [memory_limiter, batch], exporters: [clickhouse] }
    metrics: { receivers: [prometheus, otlp], processors: [memory_limiter, batch], exporters: [clickhouse] }
    logs:    { receivers: [filelog, otlp], processors: [memory_limiter, batch], exporters: [clickhouse, awss3] }
```

The `container` operator exists in collector-contrib 0.111.0. Confirm that with the validate command in Step 4.

**Step 4: Validate the config**

```bash
docker run --rm -v "$PWD/observability:/c" \
  -e CLICKHOUSE_ENDPOINT=tcp://x:9000 -e CLICKHOUSE_USER=u -e CLICKHOUSE_PASSWORD=p \
  -e LOG_ARCHIVE_REGION=eu-west-1 -e LOG_ARCHIVE_BUCKET=b \
  -e METRICS_TOKEN=t -e WEB_METRICS_TARGET=web:3000 -e WORKER_METRICS_TARGET=worker:9394 \
  otel/opentelemetry-collector-contrib:0.111.0 validate --config=/c/otel-collector.production.yaml
```

Then run the spec. Both are expected to PASS.

**Step 5: Update the RUNBOOK, then commit.** In "Logs and retention", write down:

- **Retention:** 90 days queryable in Grafana, 12 months archived in S3. Set a 13-month lifecycle rule on the bucket.
- **Restoring logs:** query the archive with Athena or ClickHouse `s3()`.
- **Quarterly check:** run a restore drill every quarter. PCI DSS 10.5.1 requires the 12-month archive to be retrievable.

Commit with the message `"Add a production collector config: container logs, 90-day ClickHouse, S3 archive"`.

## Task 8: alert rules and a contact point, provisioned and tested

`observability/grafana/provisioning/alerting/` holds only `.gitkeep`, so nothing pages anyone today. Provision one rule group backed by the ClickHouse datasource (`uid: clickhouse`), plus one contact point configured through environment variables. A spec checks that every metric we care about has a rule, and that each rule's metric name exists in `Metrics::COUNTERS` or `Metrics::GAUGES`.

**Files:**
- Create: `observability/grafana/provisioning/alerting/payhub-rules.yaml`
- Create: `observability/grafana/provisioning/alerting/contact-points.yaml`
- Create: `spec/observability/alert_rules_spec.rb`
- Modify: `docker-compose.yml`. Give the `grafana` service the variable `ALERT_WEBHOOK_URL: ${ALERT_WEBHOOK_URL:-http://mailcatcher:1080/}`; a Slack, PagerDuty or Opsgenie webhook URL goes there in production.

**Step 1: Failing test**

```ruby
# spec/observability/alert_rules_spec.rb
require "rails_helper"

RSpec.describe "Grafana alert rules" do
  let(:groups) { YAML.load_file(Rails.root.join("observability/grafana/provisioning/alerting/payhub-rules.yaml"))["groups"] }
  let(:rules) { groups.flat_map { |g| g["rules"] } }
  let(:sql) { rules.to_h { |r| [r["uid"], r["data"].find { |d| d["refId"] == "A" }.dig("model", "rawSql")] } }

  REQUIRED = {
    "payhub-stuck-unknown" => "payhub_unknown_state_payments",
    "payhub-dead-letters" => "payhub_outbound_events_dead",
    "payhub-recon-breaks" => "payhub_settlement_discrepancies_total",
    "payhub-ledger-imbalance" => "payhub_ledger_imbalance_detected_total",
    "payhub-circuit-open" => "payhub_psp_circuit_opened_total",
    "payhub-late-success" => "payhub_late_success_total",
    "payhub-audit-write-failed" => "payhub_audit_write_failed_total",
    "payhub-psp-call-in-tx" => "payhub_psp_call_in_transaction_total",
    "payhub-psp-never-received" => "payhub_psp_never_received_total",
    "payhub-stuck-alerts" => "payhub_stuck_payment_alerts_total"
  }.freeze

  it "PR-8: every required alert exists and queries its metric" do
    REQUIRED.each do |uid, metric|
      expect(sql).to have_key(uid), "missing alert #{uid}"
      expect(sql[uid]).to include("MetricName = '#{metric}'")
    end
  end

  it "PR-8: every metric an alert names is a real PayHub metric" do
    known = Metrics::COUNTERS.keys.map { "payhub_#{_1}_total" } + Metrics::GAUGES.keys.map { "payhub_#{_1}" }
    sql.values.join.scan(/MetricName = '([^']+)'/).flatten.uniq.each do |name|
      expect(known).to include(name)
    end
  end

  it "PR-8: there is an error-span rate rule and an API latency SLO rule on traces" do
    expect(sql.fetch("payhub-error-spans")).to include("otel.otel_traces").and include("StatusCode = 'Error'")
    expect(sql.fetch("payhub-slo-api-p95")).to include("quantile(0.95)(Duration)")
  end

  it "PR-8: every rule routes to the payhub contact point with a severity label" do
    rules.each do |r|
      expect(r.dig("labels", "severity")).to be_in(%w[page ticket])
      expect(r.dig("notification_settings", "receiver")).to eq("payhub-oncall")
    end
  end
end
```

**Step 2: Run it.** Expected: FAIL with ENOENT.

**Step 3: Write the rules.** One shape repeats for every rule:
- `A` is the SQL query.
- `B` reduces it to its last value.
- `C` compares that value to a threshold.

A counter's "increase over a window" is computed per series and summed, and `greatest(0, …)` absorbs counter resets.

```yaml
# observability/grafana/provisioning/alerting/payhub-rules.yaml
apiVersion: 1
groups:
  - orgId: 1
    name: payhub
    folder: PayHub
    interval: 1m
    rules:
      # ── counters: "it happened in the last N minutes" ─────────────────────
      - uid: payhub-late-success
        title: "PSP charged a payment we already failed (late success)"
        condition: C
        for: 0m
        labels: { severity: page }
        annotations:
          summary: "A customer was charged after PayHub failed the payment. Refund at the PSP."
          runbook_url: "https://github.com/baobeta/payhub/blob/master/RUNBOOK.md#7-money-questions-did-the-customer-get-charged"
        notification_settings: { receiver: payhub-oncall }
        data:
          - refId: A
            relativeTimeRange: { from: 600, to: 0 }
            datasourceUid: clickhouse
            model:
              format: 1
              rawSql: >-
                SELECT sum(d) AS value FROM (
                  SELECT greatest(0, max(Value) - min(Value)) AS d
                  FROM otel.otel_metrics_sum
                  WHERE MetricName = 'payhub_late_success_total' AND TimeUnix > now() - INTERVAL 10 MINUTE
                  GROUP BY Attributes, ResourceAttributes)
          - refId: B
            datasourceUid: __expr__
            model: { type: reduce, expression: A, reducer: last }
          - refId: C
            datasourceUid: __expr__
            model: { type: threshold, expression: B, conditions: [{ evaluator: { type: gt, params: [0] } }] }
      # …one more block like this per row of the table below…
```

Write each rule out in full, without YAML anchors: a merge key can't swap the metric name inside `data[0].model.rawSql`. That is about 20 lines per rule; 13 rules come to about 260 lines.

The full table to write:

| uid | Metric (table) | Window | Threshold | Severity | Summary |
| --- | --- | --- | --- | --- | --- |
| payhub-late-success | `payhub_late_success_total` (sum) | 10m | > 0 | page | A customer was charged after we failed the payment: refund at the PSP |
| payhub-psp-never-received | `payhub_psp_never_received_total` | 15m | > 0 | ticket | Kiripay never saw a charge; verify with the PSP |
| payhub-audit-write-failed | `payhub_audit_write_failed_total` | 10m | > 0 | page | Refusals are not being audited (PCI 10.7.2) |
| payhub-psp-call-in-tx | `payhub_psp_call_in_transaction_total` | 60m | > 0 | ticket | A PSP call ran inside a DB transaction (DECISIONS #13) |
| payhub-circuit-open | `payhub_psp_circuit_opened_total` | 5m | > 0 | page | A PSP circuit opened; payments are waiting |
| payhub-recon-breaks | `payhub_settlement_discrepancies_total` | 24h | > 0 | ticket | Settlement lines didn't match; review in the ops console |
| payhub-ledger-imbalance | `payhub_ledger_imbalance_detected_total` | 24h | > 0 | page | An unbalanced transfer exists; stop and investigate |
| payhub-stuck-alerts | `payhub_stuck_payment_alerts_total` | 15m | > 0 | page | Payments stuck past 15 min (RUNBOOK §2) |
| payhub-stuck-unknown | `payhub_unknown_state_payments` (gauge, `otel_metrics_gauge`, `max(Value)`) | 15m, `for: 15m` | > 0 | page | Payments in `unknown` for 15+ min |
| payhub-dead-letters | `payhub_outbound_events_dead` (gauge) | 15m | > 0 | ticket | Merchant webhooks dead-lettered |
| payhub-error-spans | `otel.otel_traces` with `countIf(StatusCode = 'Error') / count()` | 5m, `for: 5m` | > 0.02 | page | More than 2% of spans are errors |
| payhub-slo-api-p95 | `quantile(0.95)(Duration)/1e6` over `SpanKind = 'Server'` spans | 10m, `for: 10m` | > 300 | ticket | API p95 latency above 300 ms (SLO) |
| payhub-slo-outcome | the `payhub_unknown_state_payments` gauge, plus `payhub_stuck_payment_alerts_total` | 1h | > 0 for 1h | page | The outcome SLO is burning (Task 9) |

Gauge rules use this SQL:

```sql
SELECT max(Value) AS value FROM otel.otel_metrics_gauge
WHERE MetricName = 'payhub_unknown_state_payments' AND TimeUnix > now() - INTERVAL 5 MINUTE
```

```yaml
# observability/grafana/provisioning/alerting/contact-points.yaml
apiVersion: 1
contactPoints:
  - orgId: 1
    name: payhub-oncall
    receivers:
      - uid: payhub-oncall-webhook
        type: webhook          # Slack, PagerDuty or Opsgenie all accept an incoming webhook URL
        settings:
          url: $ALERT_WEBHOOK_URL
          httpMethod: POST
policies:
  - orgId: 1
    receiver: payhub-oncall
    group_by: [alertname]
    repeat_interval: 4h
```

**Step 4: Run it.**
- The spec is expected to PASS.
- Load the files into Grafana: run `docker compose up -d grafana`, then `curl -s -u admin:admin localhost:3300/api/v1/provisioning/alert-rules | jq length`. Expected: 13.
- Force one alert to fire: `docker compose exec -T web bin/rails runner 'Metrics.increment(:late_success, psp: "kiripay")'`. Within about 2 minutes, mailcatcher (or the webhook target) receives the alert.

**Step 5:** commit with the message `"Provision Grafana alert rules and an on-call contact point"`.

## Task 9: write down the SLOs and wire them to alerts

**Files:**
- Create: `docs/SLO.md`
- Modify: `RUNBOOK.md`. Link each alert uid to its RUNBOOK section.
- Modify: `observability/grafana/dashboards/payhub.json`. Add an "SLOs" row with two stat panels that use the same SQL as `payhub-slo-api-p95` and `payhub-slo-outcome`.

**Step 1: Write `docs/SLO.md`.** It covers each SLO, how it's measured, and which alert watches it.

| SLO | Target | Measured by | Alert |
| --- | --- | --- | --- |
| API latency | p95 < 300 ms for `/v1/*` server spans, over 28 days | `otel_traces`, server spans | `payhub-slo-api-p95` |
| Payment outcome time | 99% of payments leave `pending`/`unknown` within 2 minutes; none stays `unknown` for more than 15 minutes | the `unknown_state_payments` gauge and `stuck_payment_alerts` | `payhub-slo-outcome`, `payhub-stuck-unknown` |
| Webhook delivery | 99% of merchant events are delivered within 5 minutes when the merchant is up | `outbound_delivery_attempts` (SQL against the app DB, reported weekly) | `payhub-dead-letters` |
| Money correctness | 0 unbalanced transfers; 0 unreviewed settlement breaks older than 1 business day | `ledger_imbalance_detected`, `settlement_discrepancies` | `payhub-ledger-imbalance`, `payhub-recon-breaks` |

Also give the error budget for each SLO, and say who owns it.

**Step 2: Extend the alert-rule spec.** The PR-8 spec should also check that every uid in `docs/SLO.md`'s Alert column exists in the rules file. Parse the markdown table with a regex over `` `payhub-[a-z0-9-]+` ``.

**Step 3: Run it.** Expected: PASS. **Step 4:** commit with the message `"Define SLOs and tie them to alerts and the dashboard"`.

---

# Phase 3: ship it like production

## Task 10: production Docker image

The current `Dockerfile` is a development image:
- it runs as root and keeps the build tools
- it doesn't set `RAILS_ENV=production`
- it doesn't precompile Vite assets or bootsnap
- it is a single stage

**Files:**
- Modify: `Dockerfile`. Turn it into a multi-stage build; the dev compose keeps working through a `dev` target.
- Create: `bin/docker-entrypoint`. It wipes `$PROMETHEUS_MULTIPROC_DIR` and runs `db:prepare` only when `RUN_MIGRATIONS=true`. The wipe replaces the `rm -rf $$PROMETHEUS_MULTIPROC_DIR` in both compose commands (web and worker); remove it there.
- Modify: `docker-compose.yml`. Set `build: { context: ., target: dev }` for web, vite and worker.
- Modify: `.github/workflows/ci.yml`. Add an `image` job.

**Step 1: The failing check is a CI job.**

```yaml
  image:
    runs-on: ubuntu-latest
    services:
      postgres: { image: "postgres:16-alpine", env: { POSTGRES_USER: payhub, POSTGRES_PASSWORD: payhub, POSTGRES_DB: payhub_production }, ports: ["5432:5432"], options: "--health-cmd pg_isready --health-interval 5s --health-retries 10" }
    steps:
      - uses: actions/checkout@v4
      - run: docker build --target production -t payhub:ci .
      - name: image runs as non-root
        run: test "$(docker run --rm payhub:ci id -u)" != "0"
      - name: boots in production and answers /healthz
        run: |
          docker run -d --name app --network host \
            -e RAILS_ENV=production -e SECRET_KEY_BASE=$(openssl rand -hex 64) -e APP_HOST=ci.local \
            -e DATABASE_URL=postgres://payhub:payhub@localhost:5432/payhub_production \
            -e REDIS_URL=redis://localhost:6379/0 -e RAILS_SERVE_STATIC_FILES=true -e RUN_MIGRATIONS=true \
            -e AR_ENCRYPTION_PRIMARY_KEY=ci -e AR_ENCRYPTION_DETERMINISTIC_KEY=ci -e AR_ENCRYPTION_KEY_DERIVATION_SALT=ci \
            -e NORDPAY_URL=https://nordpay.invalid -e NORDPAY_API_KEY=ci_live -e NORDPAY_WEBHOOK_SECRET=ci \
            -e KIRIPAY_URL=https://kiripay.invalid -e KIRIPAY_API_KEY=ci_live -e KIRIPAY_WEBHOOK_SECRET=ci \
            -e METRICS_TOKEN=ci -e RAILS_FORCE_SSL=false payhub:ci
          for i in $(seq 30); do curl -sf localhost:3000/healthz && exit 0; sleep 2; done
          docker logs app; exit 1
```

`production.rb` sets `force_ssl = true`, so first make it `config.force_ssl = ENV.fetch("RAILS_FORCE_SSL", "true") == "true"`, with a comment saying TLS is terminated at the load balancer.

**Step 2: Push the branch.** Expected: the `image` job FAILS, because there is no `production` target.

**Step 3: Write the multi-stage Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1
ARG RUBY_VERSION=3.3.12
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base
WORKDIR /rails
RUN apt-get update -qq && apt-get install --no-install-recommends -y curl libpq5 && rm -rf /var/lib/apt/lists/*
ENV BUNDLE_PATH=/usr/local/bundle

FROM base AS build
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential git libpq-dev && rm -rf /var/lib/apt/lists/*
COPY --from=docker.io/library/node:22-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=docker.io/library/node:22-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm
COPY Gemfile Gemfile.lock ./
RUN bundle config set without "development test" && bundle install && \
    rm -rf ~/.bundle "$BUNDLE_PATH"/ruby/*/cache && bundle exec bootsnap precompile --gemfile
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN bundle exec bootsnap precompile app/ lib/ && \
    SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production bin/vite build && rm -rf node_modules

# Development: the old behaviour, used by docker-compose.
FROM build AS dev
RUN bundle config unset without && bundle install && npm ci
CMD ["bin/rails", "server", "-b", "0.0.0.0"]

FROM base AS production
# One metrics directory per container, on its own disk (no shared volume); the
# dev compose keeps overriding it per service (/rails/tmp/prometheus/web, /worker).
ENV RAILS_ENV=production RAILS_LOG_TO_STDOUT=1 PROMETHEUS_MULTIPROC_DIR=/rails/tmp/prometheus
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails
RUN groupadd --system --gid 1000 rails && useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p tmp log && chown -R rails:rails tmp log
USER 1000:1000
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
```

```bash
#!/bin/bash -e
# bin/docker-entrypoint (chmod +x)
rm -rf "${PROMETHEUS_MULTIPROC_DIR:?}"/* 2>/dev/null || true
if [ "${RUN_MIGRATIONS}" = "true" ]; then bin/rails db:prepare; fi
exec "$@"
```

The production assets must exist: `bin/vite build` writes them to `public/vite`. Serving them is either `RAILS_SERVE_STATIC_FILES=true` in Rails or a CDN; record that choice in Task D2.

**Step 4: Check locally, then in CI.**

```bash
docker build --target production -t payhub:local .
docker run --rm payhub:local id -u
```

Expected: 1000. Push and the `image` job PASSES. `docker compose up` still works through the dev target.

**Step 5:** commit with the message `"Build a multi-stage, non-root production image and boot-test it in CI"`.

## Task 11: Puma runs workers in production

**Files:**
- Modify: `config/puma.rb`
- Test: inside the CI image job, assert that the log shows `Puma starting in cluster mode`.

```ruby
# config/puma.rb, appended
# Production runs WEB_CONCURRENCY processes x RAILS_MAX_THREADS threads.
# DB pool = threads (database.yml); total connections = workers x threads + Sidekiq concurrency, so size PgBouncer for that.
workers Integer(ENV.fetch("WEB_CONCURRENCY", 0))
preload_app! if Integer(ENV.fetch("WEB_CONCURRENCY", 0)).positive?
```

In the CI image job, add `-e WEB_CONCURRENCY=2` and `docker logs app | grep -q "cluster mode"`. Run it; it should PASS. Commit with the message `"Run Puma in cluster mode when WEB_CONCURRENCY is set"`.

## Task 12: migrations can't lock production by accident

**Files:**
- Modify: `Gemfile`. In the development/test group, add `gem "strong_migrations", "~> 2.0"`.
- Create: `config/initializers/strong_migrations.rb`
- Modify: the existing migrations that already ran. Mark them as checked, with `StrongMigrations.start_after = <latest migration version>`.

**Step 1: Failing check.** Write a throwaway migration that adds an index without `algorithm: :concurrently`, then run `bin/rails db:migrate` in the test environment. Expected: it SUCCEEDS today, which is the problem this task fixes.

**Step 2: Implement**

```ruby
# config/initializers/strong_migrations.rb
StrongMigrations.start_after = 20261021600001 # everything up to here has already been reviewed
StrongMigrations.target_version = 16          # PostgreSQL major version
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour
```

**Step 3: Run the throwaway migration again.** Expected: FAIL with "Adding an index non-concurrently blocks writes". Delete it.

**Step 4:** Run `bundle install`, then the full suite. Commit with the message `"Guard migrations with strong_migrations"`.

## Task 13: least-privilege database roles

The append-only triggers on the ledger, audit log, call log and payment history only protect data if the app's database role can't drop or disable them. That means the app role must not own the tables and must not be a superuser.

**Files:**
- Create: `db/roles.sql`. It holds idempotent role and grant SQL for `payhub_owner`, which runs migrations, and `payhub_app`, which the runtime uses.
- Create: `spec/db/roles_spec.rb`
- Modify: `RUNBOOK.md`. Add a "Database roles" section explaining which `DATABASE_URL` each process uses.

**Step 1: Failing test**

```ruby
# spec/db/roles_spec.rb
require "rails_helper"

RSpec.describe "database roles", :concurrency do
  def as_app_role
    conn = ActiveRecord::Base.connection
    conn.execute(File.read(Rails.root.join("db/roles.sql")))
    conn.execute("SET ROLE payhub_app")
    yield conn
  ensure
    conn.execute("RESET ROLE")
  end

  it "PR-13: the app role can read and write rows" do
    as_app_role { |c| expect { c.execute("SELECT count(*) FROM payments") }.not_to raise_error }
  end

  it "PR-13: the app role cannot disable or drop the append-only triggers" do
    as_app_role do |c|
      expect { c.execute("ALTER TABLE ledger_entries DISABLE TRIGGER trg_ledger_entries_immutable") }
        .to raise_error(ActiveRecord::StatementInvalid, /must be owner|permission denied/)
      expect { c.execute("DROP TRIGGER trg_audit_events_append_only ON audit_events") }
        .to raise_error(ActiveRecord::StatementInvalid, /must be owner|permission denied/)
      expect { c.execute("SET session_replication_role = replica") }
        .to raise_error(ActiveRecord::StatementInvalid, /permission denied/)
    end
  end
end
```

**Step 2: Run it.** Expected: FAIL, because the role doesn't exist.

**Step 3: Write `db/roles.sql`**

```sql
-- Idempotent. Run as a superuser once per database, then after every
-- migration that adds a table (the default privileges below cover new tables).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'payhub_app') THEN
    CREATE ROLE payhub_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO payhub_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO payhub_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO payhub_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO payhub_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO payhub_app;
-- The triggers, not grants, stop UPDATE and DELETE on the append-only tables;
-- the app role simply can't remove them, because it owns nothing.
```

The production password is set outside the repo, with `ALTER ROLE payhub_app PASSWORD …` from the secrets manager.

**Step 4: Run it.** Expected: PASS. Then run the full suite. **Step 5:** commit with the message `"Add a least-privilege app role that cannot touch the append-only triggers"`.

## Task 14: faster CI

The suite went from about 1m20s to about 3m40s. Most of the increase is the simulation seeds and the property specs.

**Files:**
- Modify: `.github/workflows/ci.yml`, job `check`. Split RSpec across 3 parallel runners.

```yaml
    strategy: { matrix: { shard: [0, 1, 2] } }
    steps:
      # …existing setup…
      - name: rspec (shard ${{ matrix.shard }} of 3)
        run: |
          files=$(find spec -name '*_spec.rb' | sort | awk "NR % 3 == ${{ matrix.shard }}")
          bundle exec rspec $files
```

Keep `bin/check` for the non-RSpec gates (Sorbet, rubocop, eslint, exports) in a separate job, so it runs once rather than once per shard.

**Check:** push, and the slowest shard should finish in under about 1m30s. Each shard writes its own coverage report; merging them is optional.

Commit with the message `"Run the suite in three parallel shards"`.

## Task 15: clear the dependency backlog

There are 12 open dependabot PRs: #5, #6, #8, #15, #17 and #25–#31.

**Procedure:**
1. Merge the patch and minor bumps first, one at a time, after CI passes: sorbet, sorbet-runtime, brakeman, faraday, pg_query, lograge, csv, opentelemetry-instrumentation-all and the GitHub Actions bumps.
2. **Sidekiq 7 → 8 (#6)** is a major version. Read Sidekiq's 8.0 upgrade notes. Check `sidekiq-cron` compatibility (it needs a 2.x that supports Sidekiq 8). Run the full suite and the chaos job, and run `docker compose up worker` to watch one sweep before merging.
3. **connection_pool 2 → 3 (#5)** has changed keyword arguments. Merge it together with Sidekiq 8 or after it.
4. Turn on a dependabot auto-merge rule for patch versions, gated on green CI.

---

# Phase 4: decisions that need someone outside the code

Each item has an owner, the options, the exit criterion, and the code work it unlocks. Record each outcome as a new DECISIONS entry.

**D1. A real PSP, card tokenization and 3DS** (owner: business and engineering lead)
- **Options:** Adyen, Checkout.com or Stripe (as an acquiring PSP) for cards; Xendit, 2C2P or similar for SE-Asian wallets.
- **Exit criterion:**
  - signed contract and sandbox credentials
  - a tokenization approach decided (the PSP's hosted fields or drop-in, which keeps us at SAQ-A)
  - a 3DS/SCA flow decided
- **Unlocks:**
  - a new adapter behind the `PspAdapter` contract, with capability flags
  - contract specs recorded against the sandbox
  - the `requires_action` redirect for 3DS
  - certification test runs
  - per-network authorization expiry instead of a flat 6 days (USE_CASES M-1)

**D2. Hosting and deployment** (owner: engineering)
- **Options:**
  - Kamal on VMs, the smallest step from compose
  - AWS ECS or Fly.io
  - Kubernetes, which the README currently marks out of scope
- **Exit criterion:**
  - staging and production environments
  - TLS at the load balancer
  - an internal listener for `/metrics`
  - a decision between a CDN and `RAILS_SERVE_STATIC_FILES` for `public/vite`
  - zero-downtime deploys
  - a one-command rollback
- **Unlocks:** deploy config in the repo, a CI deploy job and environment secrets.

**D3. Postgres and Redis** (owner: engineering)
- **Postgres:** managed, with point-in-time recovery, a standby replica and PgBouncer. Pool size is `WEB_CONCURRENCY × RAILS_MAX_THREADS + Sidekiq concurrency`.
- **Redis:** Sidekiq queues, the cron schedule and rate-limit counters live there, so it needs AOF persistence and high availability.
- **Exit criterion:** a restore drill done and timed (RTO and RPO written in the RUNBOOK), and a Redis failover tested.

**D4. Secrets** (owner: engineering)
- A secrets manager (AWS Secrets Manager, Vault or Doppler).
- A rotation runbook for each secret: PSP keys, webhook secrets, `AR_ENCRYPTION_*`, `METRICS_TOKEN`, `SECRET_KEY_BASE`. Key rotation for `AR_ENCRYPTION` uses Rails' `previous:` keys.

**D5. Security and compliance** (owner: security)
- A PCI DSS SAQ-A self-assessment, or a QSA review if the acquirer requires one.
- An external penetration test of the API, the dashboard and the ops console.
- A GDPR erasure decision for the append-only logs: pseudonymous actor ids or crypto-shredding (USE_CASES P-9).
- Hash-chaining or WORM storage for the audit archive, which builds on Task 7's S3 archive with Object Lock.

**D6. Disputes and chargebacks** (owner: product)
- A real PSP will send disputes even though the README lists them as out of scope.
- **Minimum to build once D1 is done:**
  - ingest dispute webhooks
  - store them
  - block refunds on disputed payments
  - show them to ops and the merchant
  - account for the debit in the ledger

**D7. Merchants and money out** (owner: product)
- **Onboarding:** KYB before live keys, pausing payments or payouts, and closing an account.
- **Payouts:** bank-statement matching, a negative-balance policy, and refunds after payout (USE_CASES M-5 and P-13).
- **Exit criterion:** a written policy for each, before the first live merchant.

---

## Order of work

1. **Tasks 1–3**, the security gaps. Small, and they unblock everything else.
2. **Tasks 4–9**, observability. These can run alongside D2 and D3.
3. **Tasks 10–14**, shipping. Task 10 depends on Task 4 for its entrypoint. Task 13 is needed before D3 goes live.
4. **Task 15**, dependencies, can happen any time; Sidekiq 8 is best after Task 5.
5. **D1–D7**, run in parallel by their owners. D1 and D2 gate the first live payment.
