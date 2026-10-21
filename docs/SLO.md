# PayHub SLOs

What PayHub promises, how each promise is measured, and which alert tells on-call it is at risk. Owner of every SLO: **PayHub on-call** (the `payhub-oncall` and `payhub-tickets` contact points). What to do when an alert fires is in [RUNBOOK.md](../RUNBOOK.md#alerts-grafana).

| SLO | Target | Measured by | Alert |
| --- | --- | --- | --- |
| API latency | p95 < 300 ms for `/v1/*` server spans, over 28 days | `otel_traces`, server spans of `payhub-web` | `payhub-slo-api-p95` |
| Payment outcome time | No payment stays `unknown` for a whole hour; none stays `unknown` longer than 15 minutes | the `unknown_state_payments` gauge (from `payhub-web`) and `stuck_payment_alerts` (from `payhub-worker`) | `payhub-slo-outcome`, `payhub-stuck-unknown`, `payhub-stuck-alerts` |
| Webhook delivery | 99% of merchant events delivered within 5 minutes, when the merchant's endpoint is up; measured weekly | `outbound_events` and `outbound_delivery_attempts` in the app database | `payhub-dead-letters` |
| Money correctness | 0 unbalanced transfers; 0 unreviewed settlement breaks older than 1 business day | `ledger_imbalance_detected`, `settlement_discrepancies`, and the `/ops` queue's `reconciliation_breaks` | `payhub-ledger-imbalance`, `payhub-recon-breaks` |
| Observability itself | Both services scraped, logs flowing, every log batch archived to S3 | `up`, `otel_logs`, the collector's `otelcol_exporter_send_failed_log_records` | `payhub-scrape-down`, `payhub-logs-silent`, `payhub-archive-upload-failed` |

The alerts are **burn signals**, not the SLO figure: each fires when the SLO is being spent fast right now. Nothing computes the 28-day (or weekly) figure automatically yet. To report it, run the queries below by hand (ClickHouse keeps 90 days in production, 72 hours locally), at the end of each period, and keep the numbers.

The *PayHub tracing* dashboard's **SLOs** row shows each alert's query as it runs now: the number the alert compares with its threshold. Each stat turns red at its alert's threshold (the alert itself may still be waiting out its `for`). Each stat's header has a link to its RUNBOOK section.

How to run the queries:

- **ClickHouse:** `curl 'localhost:8123/?user=otel&password=otel' --data-binary @query.sql` (production: the ClickHouse host Grafana's datasource points at), or Grafana Explore.
- **App database:** `bin/rails dbconsole -p`, then paste. Read-only; nothing below writes.

## API latency

- **Target:** p95 of `/v1/*` request duration below 300 ms over 28 days.
- **Error budget:** 5% of `/v1` requests in 28 days may take longer than 300 ms. `pct_over_300ms` below is the budget spent: 5 means all of it.
- **Alert:** `payhub-slo-api-p95` (ticket) fires when the p95 over the last 10 minutes has been above 300 ms for 10 minutes. A 10-minute p95 above 300 ms spends budget faster than 28 days allow; it says nothing about the 28-day figure.
- **By hand** (ClickHouse; `Duration` is nanoseconds):

```sql
SELECT count() AS requests,
       round(quantile(0.95)(Duration) / 1e6, 1) AS p95_ms,
       round(100 * countIf(Duration > 300e6) / count(), 2) AS pct_over_300ms
FROM otel.otel_traces
WHERE ServiceName = 'payhub-web' AND SpanKind = 'Server' AND SpanAttributes['http.route'] LIKE '/v1/%'
  AND Timestamp >= now() - INTERVAL 28 DAY
```

## Payment outcome time

- **Target:** no payment stays in `unknown` (the PSP's answer not yet known) for more than 15 minutes, and the count of `unknown` payments is never above 0 for a whole hour.
- **Error budget:** none. Each payment past 15 minutes in `unknown` is an incident.
- **Alerts:**
  - `payhub-stuck-unknown` (page): `payhub_unknown_state_payments` from web has been above 0 for 15 minutes.
  - `payhub-stuck-alerts` (page): the sweeper raised `alert.stuck_payment`, a payment in `pending` or `unknown` for more than 15 minutes (`payhub_stuck_payment_alerts_total` from the worker rose).
  - `payhub-slo-outcome` (page, no wait): every `payhub_unknown_state_payments` sample from web in the last hour is above 0, with samples going back at least 55 minutes. It reads the gauge only, a count: it fires when payments stay `unknown` all hour, not necessarily the same payment.
- **By hand, now** (app database):

```sql
SELECT count(*) AS unknown_now,
       count(*) FILTER (WHERE t.sort_key < (now() AT TIME ZONE 'UTC') - interval '15 minutes') AS unknown_over_15m,
       min(t.sort_key) AS oldest_since
FROM payments p
JOIN payment_transitions t ON t.payment_id = p.id AND t.most_recent
WHERE p.state = 'unknown';
```

- **By hand, 28 days** (app database): payments that entered `unknown` and stayed more than 15 minutes. Should be 0.

```sql
SELECT count(DISTINCT u.payment_id) AS payments_unknown_over_15m
FROM payment_transitions u
LEFT JOIN LATERAL (
  SELECT min(n.sort_key) AS left_at FROM payment_transitions n
  WHERE n.payment_id = u.payment_id AND n.sort_key > u.sort_key
) nxt ON true
WHERE u.to_state = 'unknown'
  AND u.sort_key >= (now() AT TIME ZONE 'UTC') - interval '28 days'
  AND coalesce(nxt.left_at, now() AT TIME ZONE 'UTC') > u.sort_key + interval '15 minutes';
```

## Webhook delivery

- **Target:** 99% of merchant events are delivered within 5 minutes of being created, counting only events whose merchant endpoint was up. Reported weekly.
- **Error budget:** 1% of the week's counted events may arrive later than 5 minutes, or not at all.
- **What counts:** an event is left out when the merchant has no webhook URL (it is marked delivered with no attempt), or when any attempt in its first 5 minutes got no answer or a 5xx (the merchant was down). A 4xx counts against us: the merchant was up and refused it. An event never attempted in 5 minutes counts against us too: that is our delivery job.
- **Alert:** `payhub-dead-letters` (ticket) fires when any event has run out of retries (`payhub_outbound_events_dead` from web above 0). It is the operational signal, not the SLO: no alert watches the 5-minute figure.
- **By hand, last 7 days** (app database; events created in the last 5 minutes are not counted yet):

```sql
WITH events AS (
  SELECT e.delivered_at IS NOT NULL AND e.delivered_at <= e.created_at + interval '5 minutes' AS on_time,
         EXISTS (SELECT 1 FROM outbound_delivery_attempts a
                 WHERE a.outbound_event_id = e.id AND a.created_at <= e.created_at + interval '5 minutes'
                   AND (a.response_status IS NULL OR a.response_status >= 500)) AS merchant_down
  FROM outbound_events e
  WHERE e.created_at >= (now() AT TIME ZONE 'UTC') - interval '7 days 5 minutes'
    AND e.created_at <  (now() AT TIME ZONE 'UTC') - interval '5 minutes'
    AND NOT (e.state = 'delivered' AND e.attempts = 0) -- no webhook URL: marked delivered, never sent
)
SELECT count(*) FILTER (WHERE NOT merchant_down) AS counted,
       count(*) FILTER (WHERE NOT merchant_down AND NOT on_time) AS late,
       round(100.0 * count(*) FILTER (WHERE NOT merchant_down AND on_time)
             / nullif(count(*) FILTER (WHERE NOT merchant_down), 0), 2) AS pct_on_time,
       count(*) FILTER (WHERE merchant_down) AS excluded_merchant_down
FROM events;
```

`pct_on_time` must be at least 99. `late` over 1% of `counted` is the budget overspent. A redelivered dead event keeps its first `created_at`, so it counts as late.

## Money correctness

- **Target:** every ledger transfer nets to zero; no settlement break (an `unmatched` or `mismatch` settlement line) is left unreviewed for more than 1 business day.
- **Error budget:** none. An unbalanced transfer is a bug; an overdue break is money nobody has looked at.
- **Alerts:**
  - `payhub-ledger-imbalance` (page): the nightly reconciliation found an unbalanced transfer (`payhub_ledger_imbalance_detected_total` from the worker rose in the last 24 hours).
  - `payhub-recon-breaks` (ticket): the settlement run found lines that do not match the ledger (`payhub_settlement_discrepancies_total` rose in the last 24 hours). Reviewing them is the `/ops` Reconciliation queue (`reconciliation_breaks` on the queue page); no alert watches the 1-business-day deadline.
- **By hand** (app database; "1 business day" means a whole weekday has passed since the day the break was found; public holidays are not counted):

```sql
SELECT (SELECT count(*) FROM (
          SELECT transfer_id FROM ledger_entries GROUP BY transfer_id, currency
          HAVING sum(CASE direction WHEN 'credit' THEN amount_minor ELSE -amount_minor END) <> 0) AS t) AS unbalanced_transfers,
       (SELECT count(*) FROM settlement_lines l
        WHERE l.status IN ('unmatched', 'mismatch') AND l.reviewed_at IS NULL
          AND (SELECT count(*) FROM generate_series(l.created_at::date + 1, (now() AT TIME ZONE 'UTC')::date - 1, interval '1 day') AS d
               WHERE extract(isodow FROM d) < 6) >= 1) AS overdue_breaks;
```

Both must be 0.

## Observability itself

Every other SLO is measured through this pipeline: when it is down, they are unmeasured, not met.

- **Target:** each of `payhub-web` and `payhub-worker` scraped successfully in 99.5% of minutes over 28 days; a PayHub log line reaches ClickHouse every minute; no log record fails to reach the S3 archive.
- **Error budget:** 0.5% of minutes per service in 28 days without a successful scrape (about 3 hours 20 minutes). Log gaps and archive failures have none: each is a hole in the record that has to be backfilled.
- **Alerts:**
  - `payhub-scrape-down` (page): a service has had `up` = 0, or no scrape at all, for 5 minutes.
  - `payhub-logs-silent` (page): no PayHub log line in 15 minutes (the sweepers log every minute).
  - `payhub-archive-upload-failed` (page): the collector's `awss3` exporter failed to send log records in the last hour.
- **By hand** (ClickHouse). Scrapes: `pct_minutes_up` at least 99.5 per service.

```sql
SELECT ServiceName AS service,
       round(100 * uniqExactIf(toStartOfMinute(TimeUnix), Value = 1) / (28 * 1440), 2) AS pct_minutes_up
FROM otel.otel_metrics_gauge
WHERE MetricName = 'up' AND ServiceName IN ('payhub-web', 'payhub-worker')
  AND TimeUnix >= now() - INTERVAL 28 DAY
GROUP BY service
```

Logs: minutes in 28 days without a PayHub log line.

```sql
SELECT 28 * 1440 - uniqExact(toStartOfMinute(TimestampTime)) AS minutes_without_logs
FROM otel.otel_logs
WHERE ServiceName LIKE 'payhub%' AND TimestampTime >= now() - INTERVAL 28 DAY
```

Archive: take the `payhub-archive-upload-failed` query from `observability/grafana/provisioning/alerting/payhub-rules.yaml` and replace `INTERVAL 60 MINUTE` with `INTERVAL 28 DAY` (three places). The result is the log records missing from the archive in 28 days; it must be 0.

Locally ClickHouse keeps 72 hours, so these 28-day percentages read low; they are meaningful only in production.
