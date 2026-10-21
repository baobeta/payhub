# PayHub SLOs

What PayHub promises, how each promise is measured, and which alert tells on-call it is at risk. Owner of every SLO: **PayHub on-call** (the `payhub-oncall` and `payhub-tickets` contact points). What to do when an alert fires is in [RUNBOOK.md](../RUNBOOK.md#alerts-grafana).

| SLO | Target | Measured by | Alert |
| --- | --- | --- | --- |
| API latency | p95 < 300 ms for `/v1/*` server spans, over 28 days | `otel_traces`, server spans of `payhub-web` | `payhub-slo-api-p95` |
| Payment outcome time | No payment stays `unknown` longer than 15 minutes; `unknown` is never above 0 for a whole hour | the `unknown_state_payments` gauge (from `payhub-web`) and `stuck_payment_alerts` (from `payhub-worker`) | `payhub-slo-outcome`, `payhub-stuck-unknown`, `payhub-stuck-alerts` |
| Webhook delivery | 99% of merchant events delivered within 5 minutes, when the merchant's endpoint answers; measured weekly | `outbound_events` and `outbound_delivery_attempts` in the app database | `payhub-dead-letters` |
| Money correctness | 0 unbalanced transfers; 0 unreviewed settlement breaks older than 1 business day | `ledger_imbalance_detected`, `settlement_discrepancies`, and the `/ops` queue's `reconciliation_breaks` | `payhub-ledger-imbalance`, `payhub-recon-breaks` |
| Observability itself | Both services scraped, logs flowing, every log batch archived to S3 | `up`, `otel_logs`, the collector's `otelcol_exporter_send_failed_log_records` | `payhub-scrape-down`, `payhub-logs-silent`, `payhub-archive-upload-failed` |

The alerts are **burn signals**, not the SLO figure: each fires when the SLO is being spent fast right now. Each alert below gives its severity and its `for` (how long the condition must hold before it fires; `0s` fires at the first evaluation that sees it). Nothing computes the 28-day (or weekly) figure automatically yet. To report it, run the queries below by hand at the end of each period and keep the numbers. ClickHouse keeps 90 days in production and 72 hours locally.

The *PayHub tracing* dashboard's **SLOs** row shows each alert's query as it runs now: the number the alert compares with its threshold. A stat turns red where its alert's condition starts: from the next whole number above the threshold for an "above" alert (the values are counts, and milliseconds for p95), and below the threshold for a "below" alert. The alert itself may still be waiting out its `for`. Each stat's header has a link to its RUNBOOK section.

How to run the queries:

- **ClickHouse:** `curl 'localhost:8123/?user=otel&password=otel' --data-binary @query.sql` (production: the ClickHouse host Grafana's datasource points at), or Grafana Explore.
- **App database:** `bin/rails dbconsole -p`, then paste. Read-only; nothing below writes.

## API latency

- **Target:** p95 of `/v1/*` request duration below 300 ms over 28 days.
- **Error budget:** 5% of `/v1` requests in 28 days may take longer than 300 ms. `pct_over_300ms` below is the budget spent: 5 means all of it.
- **Alert:** `payhub-slo-api-p95` (ticket, `for: 10m`) fires when the p95 over the last 10 minutes has been above 300 ms for 10 minutes. A 10-minute p95 above 300 ms spends budget faster than 28 days allow; it says nothing about the 28-day figure. Runbook: [`payhub-slo-api-p95`](../RUNBOOK.md#payhub-slo-api-p95).
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
- **Alerts for the 15-minute clause:**
  - `payhub-stuck-alerts` (page, `for: 1m`): the sweeper raised `alert.stuck_payment`, a payment in `pending` or `unknown` for more than 15 minutes (`payhub_stuck_payment_alerts_total` from the worker rose in the last 15 minutes). This is the per-payment signal. Runbook: [`payhub-stuck-alerts`](../RUNBOOK.md#payhub-stuck-alerts).
  - `payhub-stuck-unknown` (page, `for: 15m`): `payhub_unknown_state_payments` from web has been above 0 for 15 minutes. It reads a count, so it also fires when different payments take turns in `unknown`. Runbook: [`payhub-stuck-unknown`](../RUNBOOK.md#payhub-stuck-unknown).
- **Alert for the whole-hour clause:**
  - `payhub-slo-outcome` (page, `for: 0s`): every `payhub_unknown_state_payments` sample from web in the last hour is above 0, with samples going back at least 55 minutes. It reads the gauge only, a count: it fires when payments stay `unknown` all hour, not necessarily the same payment. Runbook: [`payhub-slo-outcome`](../RUNBOOK.md#payhub-slo-outcome).
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

- **Target:** 99% of merchant events are delivered within 5 minutes of being created, counting only events whose merchant endpoint answered. Reported weekly.
- **Error budget:** 1% of the week's counted events may arrive later than 5 minutes, or not at all.
- **What counts.** An event is left out of the percentage when:
  - the merchant has no webhook URL (it is marked delivered with no attempt);
  - an attempt in its first 5 minutes was refused by our URL guard (`not delivered: webhook URL …`: the saved URL now points somewhere private). Reported as `excluded_blocked_url`;
  - an attempt in its first 5 minutes got no answer (timeout, refused connection) or a 5xx. Reported as `excluded_no_answer_or_5xx`.
- **What counts against us:** an event never attempted in its first 5 minutes (our delivery job), and a 4xx. A 4xx means the endpoint answered and refused, which can be our fault (a signature bug, a malformed payload) as easily as the merchant's, so it stays in; `late_4xx` reports those separately so the merchant's share can be argued case by case.
- **What the percentage cannot see:**
  - A PayHub-side egress outage (our network, DNS, a proxy) looks exactly like merchants not answering: those events are excluded and `pct_on_time` stays high. Cross-check with `merchants_excluded` (many merchants excluded in one week points at our egress, not theirs) and with `payhub-dead-letters`.
  - An event whose first attempt got no answer is excluded even when a retry landed within 5 minutes. That makes `pct_on_time` conservative: it never credits us for events the merchant was slow on.
  - A redelivered dead event keeps its first `created_at`, so it counts as late.
- **Alert:** `payhub-dead-letters` (ticket, `for: 0s`) fires when any event has run out of retries (`payhub_outbound_events_dead` from web above 0). It is the operational signal, not the SLO: no alert watches the 5-minute figure. Runbook: [`payhub-dead-letters`](../RUNBOOK.md#payhub-dead-letters).
- **By hand, last 7 days** (app database; events created in the last 5 minutes are not counted yet):

```sql
WITH events AS (
  -- One row per event, with what its attempts in the first 5 minutes got back.
  SELECT e.merchant_id,
         e.delivered_at IS NOT NULL AND e.delivered_at <= e.created_at + interval '5 minutes' AS on_time,
         coalesce(bool_or(a.error LIKE 'not delivered: webhook URL%'), false) AS blocked_url,
         coalesce(bool_or(a.response_status >= 500 OR (a.response_status IS NULL
                                                       AND a.error NOT LIKE 'not delivered: webhook URL%')), false) AS no_answer_or_5xx,
         coalesce(bool_or(a.response_status BETWEEN 400 AND 499), false) AS got_4xx
  FROM outbound_events e
  LEFT JOIN outbound_delivery_attempts a
    ON a.outbound_event_id = e.id AND a.created_at <= e.created_at + interval '5 minutes'
  WHERE e.created_at >= (now() AT TIME ZONE 'UTC') - interval '7 days 5 minutes'
    AND e.created_at <  (now() AT TIME ZONE 'UTC') - interval '5 minutes'
    AND NOT (e.state = 'delivered' AND e.attempts = 0) -- no webhook URL: marked delivered, never sent
  GROUP BY e.id, e.merchant_id, e.created_at, e.delivered_at
),
counted AS (
  SELECT * FROM events WHERE NOT blocked_url AND NOT no_answer_or_5xx
)
SELECT (SELECT count(*) FROM counted) AS counted,
       (SELECT count(*) FROM counted WHERE NOT on_time) AS late,
       (SELECT count(*) FROM counted WHERE NOT on_time AND got_4xx) AS late_4xx,
       (SELECT round(100.0 * count(*) FILTER (WHERE on_time) / nullif(count(*), 0), 2) FROM counted) AS pct_on_time,
       (SELECT count(*) FROM events WHERE blocked_url) AS excluded_blocked_url,
       (SELECT count(*) FROM events WHERE no_answer_or_5xx AND NOT blocked_url) AS excluded_no_answer_or_5xx,
       (SELECT count(DISTINCT merchant_id) FROM events WHERE blocked_url OR no_answer_or_5xx) AS merchants_excluded;
```

`pct_on_time` must be at least 99. `late` over 1% of `counted` is the budget overspent.

## Money correctness

- **Target:** every ledger transfer nets to zero; no settlement break (an `unmatched` or `mismatch` settlement line) is left unreviewed for more than 1 business day.
- **Error budget:** none. An unbalanced transfer is a bug; an overdue break is money nobody has looked at.
- **Alerts:**
  - `payhub-ledger-imbalance` (page, `for: 1m`): the nightly reconciliation found an unbalanced transfer (`payhub_ledger_imbalance_detected_total` from the worker rose in the last 24 hours). Runbook: [`payhub-ledger-imbalance`](../RUNBOOK.md#payhub-ledger-imbalance).
  - `payhub-recon-breaks` (ticket, `for: 1m`): the settlement run found lines that do not match the ledger (`payhub_settlement_discrepancies_total` rose in the last 24 hours). Reviewing them is the `/ops` Reconciliation queue (`reconciliation_breaks` on the queue page); no alert watches the 1-business-day deadline. Runbook: [`payhub-recon-breaks`](../RUNBOOK.md#payhub-recon-breaks).
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
  - `payhub-scrape-down` (page, `for: 5m`): a service has had `up` = 0, or no scrape at all, for 5 minutes. Runbook: [`payhub-scrape-down`](../RUNBOOK.md#payhub-scrape-down).
  - `payhub-logs-silent` (page, `for: 1m`): no PayHub log line in 15 minutes (the sweepers log every minute). Runbook: [`payhub-logs-silent`](../RUNBOOK.md#payhub-logs-silent).
  - `payhub-archive-upload-failed` (page, `for: 1m`): the collector's `awss3` exporter failed to send log records in the last hour. Runbook: [`payhub-archive-upload-failed`](../RUNBOOK.md#payhub-archive-upload-failed).
- **By hand** (ClickHouse). The scrape and log queries count from the collector's first `up` sample in the 28 days (`minutes_covered`), so a stack younger than 28 days is not read as down for the time before it existed. Time when the collector itself was down is in the denominator and counts as missed.

Scrapes: `pct_minutes_up` at least 99.5 per service.

```sql
WITH (SELECT min(TimeUnix) FROM otel.otel_metrics_gauge
      WHERE MetricName = 'up' AND TimeUnix >= now() - INTERVAL 28 DAY) AS since,
     dateDiff('minute', toStartOfMinute(since), toStartOfMinute(now())) + 1 AS minutes_covered
SELECT ServiceName AS service, minutes_covered,
       round(100 * uniqExactIf(toStartOfMinute(TimeUnix), Value = 1) / minutes_covered, 2) AS pct_minutes_up
FROM otel.otel_metrics_gauge
WHERE MetricName = 'up' AND ServiceName IN ('payhub-web', 'payhub-worker')
  AND TimeUnix >= now() - INTERVAL 28 DAY
GROUP BY service
```

Logs: minutes without a PayHub log line. Should be 0.

```sql
WITH (SELECT min(TimeUnix) FROM otel.otel_metrics_gauge
      WHERE MetricName = 'up' AND TimeUnix >= now() - INTERVAL 28 DAY) AS since,
     dateDiff('minute', toStartOfMinute(since), toStartOfMinute(now())) + 1 AS minutes_covered
SELECT minutes_covered,
       minutes_covered - uniqExact(toStartOfMinute(TimestampTime)) AS minutes_without_logs
FROM otel.otel_logs
WHERE ServiceName LIKE 'payhub%' AND TimestampTime >= since
```

Archive: log records the collector failed to upload in 28 days (the `payhub-archive-upload-failed` query over 28 days). Must be 0.

```sql
SELECT sum(rise) AS failed_log_records
FROM (
  SELECT c.TimeUnix AS TimeUnix,
         if(isNaN(c.prev),
            if(u.first_up <= c.TimeUnix - INTERVAL 30 SECOND, c.Value, 0),
            if(c.Value >= c.prev, c.Value - c.prev, c.Value)) AS rise
  FROM (
    SELECT ServiceName, ResourceAttributes['service.instance.id'] AS instance, TimeUnix, Value,
           lagInFrame(Value, 1, nan) OVER (PARTITION BY ServiceName, mapSort(Attributes), mapSort(ResourceAttributes) ORDER BY TimeUnix
                                           ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS prev
    FROM otel.otel_metrics_sum
    WHERE MetricName = 'otelcol_exporter_send_failed_log_records' AND ServiceName = 'otelcol' AND Attributes['exporter'] = 'awss3'
      AND TimeUnix >= now() - INTERVAL 28 DAY - INTERVAL 1 DAY
  ) AS c
  INNER JOIN (
    SELECT ServiceName, ResourceAttributes['service.instance.id'] AS instance, min(TimeUnix) AS first_up
    FROM otel.otel_metrics_gauge
    WHERE MetricName = 'up' AND ServiceName = 'otelcol'
      AND TimeUnix >= now() - INTERVAL 28 DAY - INTERVAL 1 DAY
    GROUP BY ServiceName, instance
  ) AS u ON c.ServiceName = u.ServiceName AND c.instance = u.instance
  WHERE c.TimeUnix >= now() - INTERVAL 28 DAY
)
```
