# RUNBOOK — PayHub on-call

You were paged: **`alert.stuck_payment`** — a payment has been in `pending` or `unknown` for more than 15 minutes. This page is written for 3am. Follow it top to bottom; every step is safe to run.

## 0. The one rule

**Never re-send a charge you cannot prove was not received.** Nothing in this runbook re-sends an authorize. If you find yourself wanting to, stop and read step 4 again. Reads (`fetch`) are always safe; writes are not.

## 1. Find the payment (30 seconds)

The alert log line carries `payment_id`, `state`, `psp_name`, `stuck_for_s`. Everything the system ever did to this payment is one grep away — web and worker log the same keys:

```bash
grep '"payment_id":"<PAYMENT_ID>"' log/*.log | jq -c '{time, kind, event, state, source, request_id, duration_ms}'
```

Or from the database, the full history in PSP-time order:

```sql
SELECT to_state, source, most_recent, to_char(sort_key,'HH24:MI:SS.MS') AS psp_time,
       to_char(created_at,'HH24:MI:SS.MS') AS heard_at, metadata
FROM payment_transitions WHERE payment_id = '<PAYMENT_ID>' ORDER BY sort_key, created_at;
```

`PspCall.where(psp_reference: p.psp_reference).order(:sent_at)` shows every call we made for this payment, including the one that timed out.

Read the last row's `metadata`. It usually tells you the story: `"error":"... ReadTimeout"` and `gave_up_at` for a timeout; `decline_code` for a decline; `stale: true` rows are events we heard about late and correctly ignored.

## 2. Decide which of four situations you are in (1 minute)

| You see | Situation | Go to |
|---|---|---|
| `state=unknown`, sweeper log lines `resolve_unknown.timeout`, further apart each time | **PSP is unreachable** — we keep asking, it keeps not answering | §3 |
| `state=unknown`, sweeper lines `sweeper.skip` with `Rejected` | **Our bug** — the PSP answers, we cannot interpret it | §5 |
| `state=pending`, no `authorize` log line at all | **Job never ran** — Sidekiq down or queue backed up | §6 |
| `state=pending` or `unknown` but the PSP simulator/dashboard shows the charge `captured` | **Webhook lost** and the sweeper has not caught up yet | §4 |

## 3. PSP unreachable

```bash
curl -s localhost:4001/healthz   # nordpay
curl -s localhost:4002/healthz   # kiripay
docker compose ps
```

If the PSP is down: **there is nothing to do to the payment.** It is in a safe state — the customer is not being charged twice, the merchant knows it is `pending`/`unknown` via `GET /v1/payments/:id` and the outbound event stream. The sweeper keeps polling with backoff (1, 2, 4, 8, 16, then every 30 minutes — DECISIONS #13) and resolves it on the first poll after the PSP answers. When the PSP comes back, don't wait for the backoff: poll the affected payments now with the command in §4. Silence the page for the PSP outage, not the payment.

`psp_circuit.opened` in the log (and `payhub_psp_circuit_opened_total`) means PayHub has stopped calling that PSP for 30 seconds at a time: new payments stay `pending`, sweeps skip it, `POST /cancel` answers a retriable 503. That is the breaker doing its job (DECISIONS #17) — nothing was sent, so nothing is ambiguous. It closes itself on the first successful probe after the PSP recovers.

If the PSP is *up* and we still time out, check `NORDPAY_URL` / `KIRIPAY_URL` in the worker's environment, then go to §5.

A deploy that fails to boot with `PspEnv::Missing` is missing a `NORDPAY_*` / `KIRIPAY_*` variable, or has one still set to the simulator's test value. The error names the variable. Set it to the real value and redeploy.

## 4. The PSP knows the answer and we don't

Ask the PSP directly, by **our** reference (never create anything):

```bash
# Nordpay (honours our reference as its X-Request-Id)
curl -s localhost:4001/charges/<PSP_REFERENCE> -H 'Authorization: Bearer np_test_key'
# Kiripay (look up by merchant_reference; may return more than one — see DECISIONS #12)
curl -s 'localhost:4002/charges?merchant_reference=<PSP_REFERENCE>' -H 'Authorization: Bearer kp_test_key'
```

- **Charge exists and is `authorized`/`captured`/`declined`:** poll it now — this applies exactly what the PSP says, with the PSP's timestamp, and books the ledger through the same code path as the worker. (Running the whole sweeper would not do: it only polls payments whose backoff has elapsed.)
  ```bash
  bin/rails runner 'StuckPaymentSweeperJob.poll_now(Payment.find("<PAYMENT_ID>"))'
  ```
  Re-read the transitions (§1). It should now be resolved. If it is still stuck, go to §5.
- **404 — the PSP has never seen it:** the request never landed. For **Nordpay**, the sweeper will re-send **with the same `psp_reference`** on its next pass (this is the only re-send in the system, only after a confirmed 404, and only because Nordpay deduplicates by that reference). Let it. For **Kiripay**, nothing is ever re-sent once `first_sent_at` is set: the sweeper keeps looking for 30 minutes (replica lag can hide a real charge), then fails the payment as `psp_never_received` and logs `resolve_unknown.psp_never_received` (DECISIONS #12). Do not re-send it by hand either; the shop asks the customer to pay again.
- **Kiripay returns two charges for one reference:** the earliest is the real one and the sweeper uses it. The later one is a duplicate Kiripay created for a retried request; the daily reconciliation flags it. Do not refund it from this runbook — hand it to the day team.

## 5. It is our bug

Symptoms: `sweeper.skip` with `PspAdapter::Rejected`, or `webhook.illegal_transition`, or an exception in the worker log.

1. Read the exception. `Rejected` carries the PSP's HTTP status and message; `IllegalTransition` names the edge (`from -> to`).
2. **Do not** hand-edit `payments.state`. It is not writable — `Payment#state=` raises — and even if you got around it, the history and the ledger would disagree with the PSP.
3. If you must move the payment tonight (merchant escalation) and the PSP's view is unambiguous, use the maker-checker flow in `/ops` — never a console (DECISIONS #23):
   1. Open the payment in `/ops` (search by its id, `ph_` reference or merchant name).
   2. Read its **PSP calls** and **inbound webhooks**. The evidence has to be on the page, not in your head: cite the call (or the webhook) that settles the outcome.
   3. **Propose resolution** — target state (`authorized` or `failed`), a reason code, what you found, and the incident ticket as the case reference.
   4. Page an approver. A *different* operator with `ops.proposals.decide` opens the proposal, reads the same evidence, and approves. The approver cannot be you.
   Only `unknown -> failed` and `unknown -> authorized` are offered. There is deliberately no `unknown -> canceled`: you cannot release a hold you cannot see (DECISIONS #10).
4. **Break-glass only.** If `/ops` is down and the payment cannot wait, a console transition remains possible — but only with two named people on the incident ticket (the operator who runs it and the approver who sanctioned it), and with the reason recorded:
   ```ruby
   p = Payment.find("<PAYMENT_ID>")
   p.transition!(:failed, sort_key: Time.current, source: "operator", metadata: { "reason" => "PSP confirms declined; ticket OPS-123", "break_glass_approved_by" => "<APPROVER_EMAIL>" })
   ```
   This writes `source: "operator"` into the history forever and bypasses the second pair of eyes. Prefer waiting for `/ops`.
5. Open a ticket with the exception, the `payment_id`, and the PSP response. The fix is code, not data.

## 6. The job never ran

```bash
docker compose ps worker
docker compose logs --tail 50 worker
docker compose exec worker bundle exec sidekiq --version   # is the process even there
```

Sidekiq down → restart it. Jobs are idempotent: every job checks the row's state first and stops if the work is done, so replaying a backlog is safe. If the queue is backed up (Sidekiq web is not mounted; check Redis: `docker compose exec redis redis-cli llen queue:payments`), the sweeper will still resolve stuck payments independently of the original job.

## 7. Money questions ("did the customer get charged?")

The **ledger** is the truth, not `payments.state` and not the PSP dashboard:

```sql
SELECT a.kind, e.direction, e.amount_minor, e.currency, e.transfer_id, e.created_at
FROM ledger_entries e JOIN ledger_accounts a ON a.id = e.account_id
WHERE e.payment_id = '<PAYMENT_ID>' ORDER BY e.created_at;
```

- Rows with `psp_receivable debit` = money taken from the customer. None → nothing was captured, whatever the state says.
- Rows with `refunds_paid credit` = money sent back.
- Every `transfer_id` must net to zero. If one doesn't, page the day team: that is `ledger_imbalance_detected` and it means a bug, not an operator error.

## 8. After the incident

- If the payment resolved by itself once the PSP came back: no action, the design worked.
- If you used `source: "operator"`: it is in the history forever, with your reason. Reconciliation at 02:15 will compare it against the PSP and flag any disagreement as `reconciliation.psp_drift`.
- If a webhook was never sent by the PSP: the sweeper caught it; consider raising the PSP's webhook reliability with them, with the `inbound_events` gap as evidence.

## Settlement discrepancies (the morning after)

`settlement.discrepancy` at ERROR comes from the 03:45 settlement run (DECISIONS #18). Never "fix" the ledger to match; read the line first:

```bash
bin/rails runner 'pp SettlementLine.discrepancies.where(settled_on: Date.yesterday).pluck(:status, :kind, :psp_reference, :gross_minor, :problem)'
```

- **`unmatched`** — the PSP paid out for a reference we have no payment for. Money moved outside our books: escalate to the day team with the line.
- **`mismatch`, "ledger captured only …"** — the PSP settled more than we captured. This is the double-charge signal: compare the PSP's charge (§4) with our transitions before anything else.
- **`mismatch`, "refund is pending in our books"** — the PSP refunded, we haven't heard yet. Poll the refund (`RefundPaymentJob.perform_now(<REFUND_ID>)`); the line stays a mismatch as a record that we were late.
- **`settlement.unsettled_capture`** (WARN) — captured more than 3 days ago and not in any report. Ask the PSP; a capture they never pay is money we are owed.

## Rotating a webhook secret (not a page — planned work)

Every verifier accepts a list of secrets, so no step below drops a webhook (DECISIONS #15).

- **A PSP's secret (inbound).** Set `NORDPAY_WEBHOOK_SECRETS=<new>,<old>` (or `KIRIPAY_…`) on web and restart; the single-secret variable is ignored while the list is set. Switch the secret in the PSP's dashboard. Once `inbound_events` shows no `signature_valid=false` rows for an hour, set the list to `<new>` alone.
- **A merchant's secret (outbound).** `bin/rails "merchants:rotate_webhook_secret[<MERCHANT_ID>]"` prints the new secret once. For 24 hours every webhook carries two `v1=` signatures, new and old, so the merchant can deploy the new secret whenever suits them in that window.

## Metrics across processes (planned work, at deploy)

`PROMETHEUS_MULTIPROC_DIR` makes every process of a service (each Puma worker, each Sidekiq process) write its metrics to files in that directory; the service's `/metrics` sums the counters and reports each gauge's most recently set value. Without it, each process keeps its own and a scrape sees only the one that answered; production logs a warning at boot when `WEB_CONCURRENCY` is set and the directory is not.

- **One directory per service**, on the container's own disk, never a volume shared between containers or hosts.
- **Wipe it when the process starts** (today the Docker Compose commands do `rm -rf`; the production image's entrypoint will).

Why each rule matters:
- A gauge's "most recent" is judged by `CLOCK_MONOTONIC`, which restarts from zero when the host reboots. Files that survive a reboot carry larger timestamps than every new write, so a stale gauge (e.g. `payhub_unknown_state_payments`) would win until they are wiped.
- Files are named by PID, and container PIDs repeat (each container counts from 1). A new process that gets an old PID reopens that file and carries on from its counter totals; two containers sharing a directory would write to the same file.
- Files of processes that have exited stay (their counts are still part of the totals) until the next wipe; that is expected, not a leak.

## A merchant reports 429s (not a page — a support ticket)

The `/v1` budget is per merchant, shared by all its keys: 300/min live, 75/min test (`config/initializers/rack_attack.rb`). Spreading traffic over more keys does not help them; batching or backing off on `Retry-After` does. `PayHub-Rate-Limited-Reason: global-rate` means the merchant's whole budget; `endpoint-rate` means the sign-in throttle (20/min per IP). Raising the budget for everyone is `RATE_LIMIT_PER_MINUTE` / `RATE_LIMIT_TEST_PER_MINUTE` on web and a restart; there is no per-merchant override. A revoked key keeps counting against its merchant for up to a minute (the key lookup is cached), then falls to the 30/min per-IP budget. A bearer string that is not shaped like a PayHub key (`sk_live_`/`sk_test_` + 16-96 letters or digits) is never looked up, and a key that is not found is not cached; both count against the 30/min per-IP budget.

The counters live in `Rails.cache`, which in production is the Redis Sidekiq uses (`REDIS_URL`, keys under `payhub-cache:`; `config/environments/production.rb`), so every web process shares one count. If Redis is down, cache errors are logged as `"event":"cache_error"` and the throttles fail open (requests pass, unthrottled) until it is back; Sidekiq will be paging for the same outage. Never point production at a per-process memory store: each limit would silently multiply by the number of processes.

## A merchant user is locked out (not a page — a support ticket)

Ten wrong passwords or codes lock an account for 30 minutes; it unlocks by itself. If it cannot wait (confirm who is asking, through the merchant's owner):

```ruby
u = MerchantUser.find_by!(email: "<email>")
u.reset_failures!
AuditEvent.record!(action: "user.unlocked_by_support", result: "success", merchant_id: u.merchant_id,
                   target: u, metadata: { "ticket" => "<TICKET-ID>" })
```

Lost phone: they sign in with a recovery code, then regenerate codes on their Profile page. Lost both: an admin or the owner resets their authenticator on the Team page (DECISIONS #25). They get an email link, valid once for 72 hours, and set up a new authenticator by opening it and entering their password; the password alone is refused like a wrong one. Link expired or used: reset again. A lost owner authenticator cannot be reset by another member; that is a support-assisted flow.

## Deploy stopped: merchant without an owner (planned work, before the deploy)

Migration `20261021500001_guard_twin_parent_and_one_owner` installs the "one active owner" and "a twin's parent is live" triggers (DECISIONS #22). It first checks the existing data and aborts the deploy with the offending merchant ids (TC-M10-3) rather than install triggers that data already breaks. Nothing was changed; fix the data, then deploy again. To find them ahead of time:

```sql
-- live merchants with active members and no active owner
SELECT m.id, m.name FROM merchants m
WHERE m.livemode
  AND EXISTS (SELECT 1 FROM merchant_users u WHERE u.merchant_id = m.id AND u.disabled_at IS NULL)
  AND NOT EXISTS (SELECT 1 FROM merchant_users u WHERE u.merchant_id = m.id AND u.disabled_at IS NULL AND u.role = 'owner');

-- test twins whose parent is not a live merchant (a twin of a twin)
SELECT t.id, t.live_merchant_id FROM merchants t JOIN merchants p ON p.id = t.live_merchant_id WHERE NOT p.livemode;
```

An ownerless merchant: agree with the merchant who becomes owner (an active, enrolled admin) and promote them, the promote half of an ownership transfer (`TransferOwnership`; there is no current owner to demote). The trigger is not installed yet, so this is a plain update:

```ruby
u = MerchantUser.find_by!(merchant_id: "<merchant id>", email: "<new owner email>")
u.update!(role: "owner")
AuditEvent.record!(action: "team.ownership_transferred", result: "success", merchant_id: u.merchant_id,
                   target: u, actor_label: "support", metadata: { "ticket" => "<TICKET-ID>", "to" => u.email })
```

If nobody suitable is left, `bin/rails "merchants:invite_owner[<merchant id>,<email>]"` invites one. A twin of a twin: point its `live_merchant_id` at the live merchant at the top of the chain (or delete the empty twin), then deploy.

## Logs and retention

PCI DSS 10.5.1: keep audit logs 12 months, the last 3 immediately available.

- **90 days queryable in Grafana.** The production collector writes logs, traces and metrics to ClickHouse with a 2160h TTL; older rows drop out.
- **12 months archived in S3.** Every PayHub JSON log line (requests, jobs, and every `"event"` line: `psp_call`, `webhook.*`, `settlement.*`, `alert.*`, …) also goes to `s3://$LOG_ARCHIVE_BUCKET/payhub/logs/year=YYYY/month=MM/day=DD/hour=HH/` as OTLP JSON. The bucket, set up outside this repo, needs a lifecycle rule that expires objects after **13 months** (one month of slack over the requirement), and should block deletes before then (S3 Object Lock in compliance mode is optional, but it is what proves no one trimmed the archive).

**Running the production collector.** `otelcol-contrib --config=/etc/otelcol/config.production.yaml`, with `observability/otel-collector.production.yaml` mounted there. It reads each container's stdout from Docker's json-file log files, keeps the lines of web and worker only, and of those every JSON line: request and job lines (`"kind"`) and every structured `"event"` line. Plain-text lines (Rails' own, a few boot warnings) are dropped, so anything that must reach the archive has to be logged as JSON. Request and job lines keep their own `time`; event lines take the time Docker recorded. In ClickHouse a line's `ServiceName` is `payhub-web` or `payhub-worker` (as for traces and metrics) and `ResourceAttributes['container.id']` says which container; the `Body` is the JSON line itself and the severity comes from the line's level letter.

In the production compose file:

```yaml
x-app-logging: &app-logging            # web and worker
  driver: json-file
  options:
    env: OTEL_SERVICE_NAME             # Docker writes it into every line: the collector keeps only these
    max-size: 50m                      # rotate; the collector also reads the rotated <id>-json.log.N files
    max-file: "5"                      # no `compress`: a gzipped rotated file cannot be read
services:
  web:    { logging: *app-logging, environment: { OTEL_SERVICE_NAME: payhub-web,    METRICS_TOKEN: "${METRICS_TOKEN:?set METRICS_TOKEN}" } }
  worker: { logging: *app-logging, environment: { OTEL_SERVICE_NAME: payhub-worker, METRICS_TOKEN: "${METRICS_TOKEN:?set METRICS_TOKEN}" } }
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.111.0
    command: ["--config=/etc/otelcol/config.production.yaml"]
    user: "0"                          # Docker's log files are root:root 0640 in 0710 directories
    environment:
      METRICS_TOKEN: "${METRICS_TOKEN:?set METRICS_TOKEN}"   # plus every variable in the table below
    volumes:
      - ./observability/otel-collector.production.yaml:/etc/otelcol/config.production.yaml:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - otelcol-storage:/var/lib/otelcol/storage   # read positions + ClickHouse queue; must survive restarts
volumes:
  otelcol-storage:
```

- **Without `env: OTEL_SERVICE_NAME`** on a container, none of its lines reach ClickHouse or the archive. After any change to the logging options, check that `SELECT ServiceName, count() FROM otel.otel_logs WHERE Timestamp > now() - INTERVAL 10 MINUTE GROUP BY ServiceName` shows both services. Logging options apply only to containers created after the change.
- **Permissions.** The image runs as uid 10001, which cannot read Docker's logs. Run it as `user: "0"` with the mount read-only (or give uid 10001 read access through a group and ACL). Otherwise filelog only logs permission errors and the archive stays empty, with nothing else failing.
- **Restarts.** Read positions are checkpointed in `/var/lib/otelcol/storage`, so a restarted collector resumes where it stopped. Lines written while it was down are delivered when it starts again, as long as Docker has not rotated them away in the meantime (with the settings above, 250 MB per container). Without that volume, a restart starts at the end of every file and loses the gap. ClickHouse batches wait in the same volume while ClickHouse is down.
- **S3 outage.** The 0.111.0 S3 exporter has no queue and no retry: a batch whose upload fails is dropped from the archive (the collector logs an `awss3` export error) but is still in ClickHouse for 90 days. Alerting on failed uploads, from the collector's own metrics, comes with the Grafana alert rules (Task 8); until then, check the collector's logs. Backfill it from ClickHouse before then, under its own prefix so it is not mistaken for the collector's output:
  `INSERT INTO FUNCTION s3('https://<bucket>.s3.<region>.amazonaws.com/payhub/logs-backfill/<from>_<to>.jsonl.gz', 'JSONEachRow') SELECT Timestamp, ServiceName, SeverityText, Body, LogAttributes FROM otel.otel_logs WHERE Timestamp >= '<from>' AND Timestamp < '<to>'`
- **Long lines.** Docker splits a line over 16KB into chunks; the collector joins them again, up to 1MiB (a longer one is stored as several records of about 1MiB). Keep log lines short anyway: never log a body or a payload.
- **Network.** The OTLP receivers (4317, 4318) accept anything sent to them, without authentication. Expose them only on the internal network that web and worker use, never on a public interface.
- **Retention.** The TTL is set when the exporter creates the tables, the same 90 days for logs, traces and metrics. Changing `ttl` later does not alter existing tables; run e.g. `ALTER TABLE otel.otel_logs MODIFY TTL TimestampTime + toIntervalDay(<days>)` (and the same for `otel_traces` and `otel_metrics_*`, whose TTL columns differ: `SHOW CREATE TABLE` first).

The collector cannot refuse to start without a variable, so the deploy must set all of these:

| Variable | What |
|---|---|
| `CLICKHOUSE_ENDPOINT`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` | ClickHouse, e.g. `tcp://clickhouse.internal:9000?dial_timeout=10s` |
| `LOG_ARCHIVE_REGION`, `LOG_ARCHIVE_BUCKET` | The archive bucket. AWS credentials come from the default chain (instance role or `AWS_*`) |
| `WEB_METRICS_TARGET`, `WORKER_METRICS_TARGET` | `host:port` of web's and the worker's `/metrics` (the worker serves on 9394) |
| `METRICS_TOKEN` | The same value web and worker have. Unset or different, every scrape gets 401: `up` is 0 and the metrics panels go empty |

In any production compose file, write `METRICS_TOKEN: ${METRICS_TOKEN:?set METRICS_TOKEN}` (for the collector, web and worker, as above) so a missing token stops the deploy instead of the scrape.

**Querying the archive** (an incident or an auditor asks about something older than 90 days). From ClickHouse, with the `s3()` table function (credentials as its extra arguments, or the server's own); narrow the path to the days you need. Objects are partitioned by the hour they were *uploaded*, not the hour of the line, so widen the range by an hour either side:

```sql
SELECT fromUnixTimestamp64Nano(toInt64(JSONExtractString(rec, 'timeUnixNano'))) AS ts,
       JSONExtractString(rec, 'body', 'stringValue') AS body
FROM (
  SELECT arrayJoin(JSONExtractArrayRaw(scope, 'logRecords')) AS rec
  FROM (
    SELECT arrayJoin(JSONExtractArrayRaw(arrayJoin(JSONExtractArrayRaw(json, 'resourceLogs')), 'scopeLogs')) AS scope
    FROM s3('https://<bucket>.s3.<region>.amazonaws.com/payhub/logs/year=2026/month=03/day=14/hour=*/*', 'JSONAsString')
  )
)
WHERE body LIKE '%"payment_id":"<PAYMENT_ID>"%'
ORDER BY ts
```

Lines backfilled from ClickHouse (see "S3 outage" above) are under `payhub/logs-backfill/`, one row per line:

```sql
SELECT Timestamp, ServiceName, Body
FROM s3('https://<bucket>.s3.<region>.amazonaws.com/payhub/logs-backfill/*', 'JSONEachRow')
WHERE Body LIKE '%"payment_id":"<PAYMENT_ID>"%'
ORDER BY Timestamp
```

Athena works too (a table over `payhub/logs/` partitioned by year/month/day/hour), if one has been set up.

**Quarterly restore drill.** Once a quarter, pick a payment from 6–12 months ago, find its lines under both prefixes (`payhub/logs/` and `payhub/logs-backfill/`, with the two queries above), and check the collector's logs for the quarter for `awss3` export errors (each one is a gap that needs a backfill while ClickHouse still has it). Record with the team's audit evidence the date, the payment, how long it took and anything that did not work (missing hours, a credential that had expired). An archive that has never been read is not evidence.

## Quick reference

| Question | Where |
|---|---|
| What happened to payment X? | `grep '"payment_id":"X"' log/*.log` — one line per request and job |
| What state, and how did it get there? | `payment_transitions` ordered by `sort_key` |
| Did money move? | `ledger_entries` for the payment |
| What did the PSP tell us? | `inbound_events` (`signature_valid=false` rows were rejected, never processed) |
| What did we tell the merchant? | `outbound_events` + `outbound_delivery_attempts`; `POST /v1/events/:id/redeliver` for dead ones. Retries back off 1m, 5m, 30m, 2h, 8h, 24h, 36h; dead after attempt 8 (~70.6h). A redelivery gets a fresh 8-attempt budget on the same schedule; attempt numbers continue from where they stopped |
| Backlog right now | `/metrics`: `payhub_unknown_state_payments`, `payhub_outbound_events_pending`, `payhub_outbound_events_dead` |
| Job counters (late success, stuck-payment alerts, settlement discrepancies, PSP call in transaction) | The worker's own `/metrics` on port 9394 (`WORKER_METRICS_PORT`), same bearer token; not in the web scrape. `docker compose exec worker curl -s -H "Authorization: Bearer $METRICS_TOKEN" localhost:9394/metrics`. In ClickHouse: `ServiceName = 'payhub-worker'` (web is `'payhub-web'`) |
