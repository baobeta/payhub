# RUNBOOK — PayHub on-call

You were paged: **`alert.stuck_payment`** — a payment has been in `pending` or `unknown` for more than 15 minutes. This page is written for 3am. Follow it top to bottom; every step is safe to run.

Paged by Grafana? The alert's `runbook_url` points at its row in [Alerts](#alerts-grafana), which says where to start. A `DatasourceError` alert carries the failing rule's `runbook_url` too, but the rule could not run: see [DatasourceError](#datasource-error) first.

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

Every counter is registered when a process boots, because a scrape lists only the metrics registered in the process serving it: that is what lets a counter raised in another Puma worker, a Sidekiq job or a `bin/rails runner` show up in every scrape of that service. Gauges are not registered at boot (registering one would write 0 as its newest value and hide what the sweeper set); the process serving each scrape sets them itself, web on every scrape and Sidekiq on every sweep. So a worker scrape shows its gauges only once a sweep has run since it started.

- **One directory per service**, on the container's own disk, never a volume shared between containers or hosts.
- **Wipe it when the process starts.** `bin/docker-entrypoint` does it on every container start, in production and in Docker Compose; the image's default is `/rails/tmp/prometheus`.

Why each rule matters:
- A gauge's "most recent" is judged by `CLOCK_MONOTONIC`, which restarts from zero when the host reboots. Files that survive a reboot carry larger timestamps than every new write, so a stale gauge (e.g. `payhub_unknown_state_payments`) would win until they are wiped.
- Files are named by PID, and container PIDs repeat (each container counts from 1). A new process that gets an old PID reopens that file and carries on from its counter totals; two containers sharing a directory would write to the same file.
- Files of processes that have exited stay (their counts are still part of the totals) until the next wipe; that is expected, not a leak.

## Database roles (planned work, before the first deploy with them)

The append-only triggers (ledger, audit log, PSP call log, payment history) only hold if the role the app connects as cannot drop or disable them. `db/roles.sql` creates two roles:

| Role | Used by | Can |
| --- | --- | --- |
| `payhub_app` | Web (Puma) and worker (Sidekiq): their `DATABASE_URL` | Read and write rows (`SELECT`, `INSERT`, `UPDATE`, `DELETE`; sequences). Owns nothing and is no superuser, so it cannot `ALTER`, `DISABLE` or `DROP` a trigger (`must be owner of table …`), skip them with `SET session_replication_role = replica` (`permission denied to set parameter`), `TRUNCATE`, create tables (temp tables included: `TEMPORARY` on the database is revoked from `PUBLIC`, so no temp table can stand in for one a trigger reads) or grant anything; `schema_migrations` and `ar_internal_metadata` are read-only to it. The triggers still refuse its `UPDATE` and `DELETE` on the append-only tables, apart from what each one lets through (the purge of audit and PSP-call rows older than 12 months; clearing `payment_transitions.most_recent`). |
| `payhub_owner` | The migration step only: the `bin/rails db:prepare` release task, or the one-off container with `RUN_MIGRATIONS=true` whose command is `true` | Owns every table, sequence, function and type in `public`; creates and alters them. |

The entrypoint and Rails read only `DATABASE_URL`, so the release container gets the owner's URL and nothing else does. With the README's commands:

```bash
docker run --rm --env-file production.env -e DATABASE_URL="$OWNER_DATABASE_URL" payhub bin/rails db:prepare
# or, as an init container / one-off task: ... -e RUN_MIGRATIONS=true -e DATABASE_URL="$OWNER_DATABASE_URL" payhub true
docker run --env-file production.env -p 3000:3000 payhub   # production.env: DATABASE_URL=postgres://payhub_app:…@…/payhub_production
```

Never put the owner URL or `RUN_MIGRATIONS` in the web or worker environment: a container that migrates and then starts Puma or Sidekiq serves traffic as the owner. The entrypoint refuses `RUN_MIGRATIONS=true` with a server command (exit 1, `refusing RUN_MIGRATIONS=true with a server command`); `ALLOW_MIGRATE_AND_SERVE=true` overrides that, for single-container setups with one database user only. The owner URL also bypasses PgBouncer: it points at Postgres itself (or a session-mode pool), because the migration's session `SET`s (strong_migrations' lock and statement timeouts) would leak into app traffic through a transaction-mode pool, and its advisory lock would not hold. Development and the test suite keep using the Compose superuser (`payhub`); the suite's cleanup TRUNCATEs and switches to replica mode, which `payhub_app` is refused. `spec/db/roles_spec.rb` checks the roles themselves.

**Once per database** (production, staging), as a superuser:

1. `psql "$SUPERUSER_URL" -1 -v ON_ERROR_STOP=1 -f db/roles.sql`, connected to that database (`-1`: one transaction, so a rerun on a live database never leaves the app without its grants). It creates both roles, makes `payhub_owner` the owner of every existing table, sequence, function and type in `public` (whoever ran the migrations until now, so this is the one-time ownership transfer), gives `payhub_owner` `CREATE` on the database and the schema, takes `TEMPORARY` on the database from `PUBLIC` (every non-superuser role in that database loses it; grant it back by name to one that needs it), and resets `payhub_app` to exactly its rows: anything granted to it by hand (`TRUNCATE`, a role membership) is revoked. It is idempotent: running it again changes nothing.
2. Set both passwords, never in the repo: `bin/generate-secrets` prints them (`APP_DB_PASSWORD`, `OWNER_DB_PASSWORD`; kept in `production.env` until there is a secrets manager, [Secrets](#secrets)). Use `\password payhub_app` and `\password payhub_owner` in psql (keeps them out of shell history), or `ALTER ROLE payhub_app PASSWORD '…'`.
3. Point the release container at `payhub_owner` and web and worker at `payhub_app`, then deploy.
4. Check from a web container: `bin/rails runner 'p ActiveRecord::Base.connection.select_value("SELECT current_user")'` prints `"payhub_app"`; `ALTER TABLE ledger_entries DISABLE TRIGGER trg_ledger_entries_immutable` as that user fails with `must be owner of table ledger_entries`.

**When to rerun `db/roles.sql`.** Not after normal deploys: tables and sequences that `payhub_owner` creates are granted to `payhub_app` automatically (`ALTER DEFAULT PRIVILEGES FOR ROLE payhub_owner`). Rerun it when an object was created by any other role (a migration run with the old or superuser URL, a hand-made table): until then `payhub_app` gets `permission denied for table …` on it, and the owner cannot alter it. Rerun it, too, for each new database (grants are per database, the roles are not), and after the first `db:prepare` of an empty one, which creates `schema_migrations` and `ar_internal_metadata` with the default grants: the rerun makes them read-only to `payhub_app`.

On a managed service whose admin user is not a true superuser (RDS, Cloud SQL), the file is untested: handing objects to `payhub_owner` needs the admin to be a member first (`GRANT payhub_owner TO <admin>`), and changing role attributes may be refused. An empty database where the provider (or a superuser) already created `pgcrypto` fails the owner's first `db:prepare` at `COMMENT ON EXTENSION pgcrypto` (`must be owner of extension pgcrypto`): run that first `db:prepare` with the superuser's URL instead, then rerun `db/roles.sql`, which hands every table, function and sequence to `payhub_owner` (the extension stays with whoever created it, which migrations never need to change).

## Connection pooling (PgBouncer)

Web and worker reach Postgres through PgBouncer in **transaction mode**: a client holds a server connection only for one transaction (or one statement outside a transaction), then it goes back to the pool for any other client. In Compose that is the `pgbouncer` service (`edoburu/pgbouncer:v1.25.2-p0`, PgBouncer 1.25.2), configured by `config/pgbouncer/pgbouncer.ini`; web and worker's `DATABASE_URL` is `…@pgbouncer:6432/payhub_development?advisory_locks=false&prepared_statements=false`.

**The rules transaction mode imposes on app code.** Anything that lives in the *session* stays on the server connection, not with the client: the next transaction may run on another server connection, and the next client on this one gets the leftovers.

| Don't (through the pool) | Do instead |
| --- | --- |
| `SET …` / `SET SESSION …` (a timeout, `search_path`, `session_replication_role`) | `SET LOCAL …` inside the transaction, or a role/database default (`ALTER ROLE … SET`) |
| Session advisory locks (`pg_advisory_lock`, `pg_try_advisory_lock`) | `pg_advisory_xact_lock` inside a transaction, or a row lock |
| `LISTEN` / `NOTIFY` consumers, `WITH HOLD` cursors, temp tables kept across transactions | A direct connection (not through the pool) |
| SQL-level `PREPARE` / `DEALLOCATE` | Nothing: they act on whichever server connection the statement lands on. Rails' own prepared statements are off on the pooled URL (`prepared_statements=false`) until Postgres 17, below |

**Rules for code under transaction pooling.** `bin/check` fails on the first three (step "transaction pooling"; a line may opt out with `# pooling-allow` and a reason):

- No session `SET` in app code: `SET LOCAL` inside a transaction, or `ALTER ROLE payhub_app SET …` / `ALTER DATABASE … SET …` for a lasting default. The gate matches upper-case `SET` at the start of a SQL string.
- No session advisory locks (`pg_advisory_lock`, `pg_try_advisory_lock`, `with_advisory_lock`): `pg_advisory_xact_lock` inside a transaction, or a row lock (`with_lock`, `.lock`).
- No `LISTEN` / `NOTIFY` / `pg_notify`, `WITH HOLD` cursors or temp tables (`CREATE TEMP`).
- No transaction held open across a PSP call or other network I/O (DECISIONS #7): PgBouncer cuts a client idle in a transaction for 60 s (`idle_transaction_timeout`).
- Keep transactions short: a request that waits 15 s for a server connection gets an error (`query_wait_timeout`).
- Migrations, schema loads and anything else DDL go direct (next paragraphs), never through the pool.

Today the app takes only transaction-scoped row locks (`with_lock`, `.lock`, `FOR UPDATE SKIP LOCKED`), no advisory locks, no `LISTEN`/`NOTIFY` (Action Cable, whose Postgres adapter uses `LISTEN`, is not loaded), and `config/database.yml` sets no `variables:` or `schema_search_path`. What Rails itself does on connect is covered: PgBouncer tracks `TimeZone` (Rails' `SET timezone TO 'UTC'`), `client_encoding`, `standard_conforming_strings` and, via `track_extra_parameters`, `IntervalStyle` (Rails' `iso_8601`) per client and replays them on whichever server connection the client gets; `client_min_messages` is not tracked and only changes which notices reach the log. `?advisory_locks=false` in the pooled URL stops Rails taking session advisory locks (its migration lock is the only one it would take). `server_reset_query` (`DISCARD ALL`) does not run between transactions in this mode, so nothing cleans up a session `SET`: that is why the next paragraph matters.

**What must bypass the pool.** Every `bin/rails db:*` task: `migrate`, `prepare`, `schema:load`, `seed`, `rollback`; and the test env. strong_migrations' `lock_timeout` (10 s) and `statement_timeout` (1 h) are session `SET`s and would stay on a pooled server connection, and Rails' migration lock is a session advisory lock that would not hold. The first two below keep `db:` tasks off the pool, the third the test env:

- `lib/tasks/direct_database.rake` hooks `db:load_config`, which every `db:` task depends on (from the command line or `Rake::Task["db:…"].invoke`): with `MIGRATION_DATABASE_URL` set (Compose: `db:5432`, Postgres itself) it replaces `DATABASE_URL` and reconnects; without it, a pooled `DATABASE_URL` (`advisory_locks` false, in any spelling Rails accepts) aborts the task with `DATABASE_URL is the pooled URL`. The switch is per process: `bin/rails db:migrate chaos:run` runs `chaos:run` direct too.
- `config/initializers/pooled_connection_guard.rb` refuses, on a connection without advisory locks, every other route to DDL: `Migrator#migrate`/`#run` (`DatabaseTasks.migrate`, the development error page's "Run pending migrations" button), a single `Migration#migrate` in a console or runner, `DatabaseTasks.load_schema` (`maintain_test_schema!`) and `purge` (`refusing to … through a transaction-mode pool`).
- Also direct, the test env (rspec, `bin/rails … -e test`, `RAILS_ENV=test`, `db:test:prepare`): specs `TRUNCATE` and use non-LOCAL `SET session_replication_role` and `SET ROLE`, which would leak through the pool. It reads only `config/database.yml`: `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD` and the database `TEST_DATABASE` (default `payhub_test`). Compose sets `PGHOST=db`, `PGPORT=5432`, so inside web and worker that is Postgres itself, and in the test env `config/application.rb` drops a `DATABASE_URL` or `MIGRATION_DATABASE_URL` that names a database other than a test one (Compose's two point at `payhub_development`). So `docker compose exec web bin/rails db:test:prepare` and `docker compose exec web bundle exec rspec` run on `db:5432/payhub_test` with advisory locks on, never on the dev database: `spec/rails_helper.rb` forces `RAILS_ENV=test` (the container's is `development`) and aborts if the env is anything else, and each dropped URL is reported on stderr (`[test_database] ignoring DATABASE_URL: "payhub_development" is not a test database`; the database name only). A URL with no database in it is kept: Rails takes the database from `config/database.yml`. As a fail safe, a test database whose name has no `_test` or `_e2e` part (`payhub_test`, `payhub_test_<lane>`, `payhub_e2e`) is refused at boot of the test env, and by `db:test:*` purges, schema loads and truncates from any env (`refusing to use "payhub_development" as the test database`; `config/initializers/test_database_guard.rb`), and so is the `:concurrency` cleanup's `TRUNCATE` on one. `spec/rails_helper.rb` also drops the simulator and collector URLs Compose sets (`NORDPAY_URL`, `KIRIPAY_URL`, `OTEL_EXPORTER_OTLP_*`, `OTEL_TRACES_EXPORTER`) before boot, so the full suite passes in the container as it does natively.

In production the migration container (the `db:prepare` release task, or `RUN_MIGRATIONS=true` running `true`) gets the owner's direct URL as `DATABASE_URL` ([Database roles](#database-roles-planned-work-before-the-first-deploy-with-them)). Also direct: a psql session that `SET`s anything (`bin/rails dbconsole` inside the web container is pooled: a `SET` typed there stays on a server connection; use `docker compose exec db psql -U payhub payhub_development`), `pg_dump`, and long maintenance. The test suite connects to Postgres directly, natively and inside the web container alike (list above).

**Inspecting the pool.** The admin console is the database `pgbouncer` (`admin_users = payhub`):

```bash
docker compose exec pgbouncer psql -h localhost -p 6432 -U payhub pgbouncer -c 'SHOW POOLS'
#   cl_active / cl_waiting: clients with / waiting for a server connection. cl_waiting > 0 or a
#   growing maxwait: default_pool_size is too small for the transactions running at once.
#   sv_active / sv_idle: server connections in a transaction / free.
docker compose exec pgbouncer psql -h localhost -p 6432 -U payhub pgbouncer -c 'SHOW STATS'    # xacts, queries, wait time per database
docker compose exec pgbouncer psql -h localhost -p 6432 -U payhub pgbouncer -c 'SHOW CLIENTS'  # who is connected (web, worker by address)
docker compose exec pgbouncer psql -h localhost -p 6432 -U payhub pgbouncer -c 'SHOW SERVERS'
```

After editing `pgbouncer.ini`: `docker compose exec pgbouncer psql … -c 'RELOAD'` (most settings; `listen_addr` and `listen_port` need `docker compose restart pgbouncer`). `RECONNECT` closes every server connection as soon as it is free: the cure if a session `SET` did reach the pool (a `SHOW lock_timeout` through the pool that is not `0`).

**Sizing.** Two numbers, from the same formula as README "Configuration" (web containers × `WEB_CONCURRENCY` × `RAILS_MAX_THREADS` + worker containers × Sidekiq concurrency):

| Setting | Means | Compose | Production |
| --- | --- | --- | --- |
| `default_pool_size` | Server connections per database and user: the most transactions at once | 10 (1 × 1 × 3 + 1 × 5 = 8, plus a console) | That formula, plus a few; with `reserve_pool_size` and the direct connections (migrations, psql, monitoring), below Postgres' `max_connections` |
| `max_client_conn` | Client sockets PgBouncer accepts (cheap) | 200 | At least the sum of every Active Record `pool` (it defaults to 5 per process, `config/database.yml`) + consoles, with room for a rolling deploy running old and new containers at once |
| `max_db_connections` | Hard cap per database across users | 40 | Below `max_connections` minus the direct connections |

**Prepared statements.** Off on the pooled URL (`prepared_statements=false`) while Postgres is 16. Rails frees a cached statement (cache full at `statement_limit`, 1000; a column change) with SQL `DEALLOCATE a1` unless the *server* is Postgres 17+ and the client is pg ≥ 1.6 on libpq ≥ 17 (the image has libpq 18), in which case it sends the protocol-level Close. PgBouncer 1.21+ tracks protocol-level statements and renames them per server connection, so the SQL `DEALLOCATE a1` reaches a connection that has no `a1`: `prepared statement "a1" does not exist`, and inside a transaction that error aborts it (`current transaction is aborted`). Reproduced here with `statement_limit=3`. After the upgrade to Postgres 17, drop `prepared_statements=false` from the URL; `max_prepared_statements = 500` is already set.

**TLS.** Locally the pool and Postgres talk plaintext on the private compose network, on purpose. In production both legs are encrypted and verified: the app connects with `sslmode=verify-full&sslrootcert=<CA>` in `DATABASE_URL`, and PgBouncer presents a certificate (`client_tls_sslmode = require`, `client_tls_key_file`, `client_tls_cert_file`); PgBouncer verifies Postgres with `server_tls_sslmode = verify-full` and `server_tls_ca_file`. The migration container's direct URL also takes `sslmode=verify-full`. Commented examples are at the end of `pgbouncer.ini`. A managed pooler (RDS Proxy, the Cloud SQL connector, Supabase's or Neon's poolers) brings its own TLS setup; follow its documentation, and keep the transaction-mode rules above.

**Troubleshooting.** `prepared statement "a1" does not exist` or `current transaction is aborted` after one: `prepared_statements=false` is missing from `DATABASE_URL` (above). `DATABASE_URL is the pooled URL` from a `db:` task, or `refusing to migrate through a transaction-mode pool`: set `MIGRATION_DATABASE_URL` (Compose already does on web and worker) and run it as a `db:` task. `query_wait_timeout` errors: every server connection was busy for 15 s; raise `default_pool_size` (Sizing) or find the long transactions (`SHOW SERVERS`, `pg_stat_activity`). `idle transaction timeout` in the PgBouncer log: a client sat in an open transaction for 60 s without sending anything. `no such user` / `SASL authentication failed` in the PgBouncer log: its `userlist.txt` (written at start from `DB_USER` / `DB_PASSWORD`) disagrees with the role's password; `POSTGRES_PASSWORD` changed after the `pgdata` volume was created.

## Redis persistence

Redis is not the source of truth, but it holds work that exists nowhere else until it runs: Sidekiq's queues (`payments`: the PSP calls behind authorize, capture and refund), its scheduled set and retry set, the dead set, the cron schedule that drives every sweeper (sidekiq-cron, loaded from `config/schedule.yml` only when a worker boots), and in production the rate-limit counters and API-key cache (`Rails.cache`, keys under `payhub-cache:`) and each PSP's circuit-breaker state.

**Locally.** Compose runs `redis-server --appendonly yes --appendfsync everysec --maxmemory-policy noeviction` with the default RDB snapshots (`save 3600 1 300 100 60 10000`), on the named volume `redis-data` (`/data`). There is no `maxmemory` locally (`0`, the machine's memory is the limit), so the policy only matters once one is set. The AOF is compacted by Redis' defaults, which are fine: a rewrite when it has grown 100 % since the last one (`auto-aof-rewrite-percentage 100`) and is at least 64 MB (`auto-aof-rewrite-min-size`), with an RDB preamble (`aof-use-rdb-preamble yes`). Check with `docker compose exec redis redis-cli CONFIG GET maxmemory-policy`. `docker compose restart redis`, `docker compose up -d --force-recreate redis` and a crash (SIGKILL) all keep the data; at most the last second of writes is lost on a crash. `docker compose down -v` deletes the volume, and with it everything above. Check it with `docker compose exec redis redis-cli INFO persistence` (`aof_enabled:1`, `aof_last_write_status:ok`, `rdb_last_bgsave_status:ok`).

**What is lost with Redis' data**, and what brings it back:

| Lost | Effect | Recovered by |
| --- | --- | --- |
| The cron schedule | No sweeper runs: nothing polls stuck payments, delivers outbound webhooks or expires authorizations | Restarting the worker (it reloads `config/schedule.yml`). Do it first, after any Redis data loss |
| Queued and scheduled jobs, retries | PSP calls not made | Once the cron schedule is back, the stuck-payment sweeper re-drives payments in `pending` or `unknown` and pending refunds from Postgres, and outbound webhooks are delivered from their table. Anything else: [§6](#6-the-job-never-ran) |
| The dead set | The record of jobs that exhausted their retries | Nothing: it is evidence, not work. The JSON job logs still have each failure |
| Rate-limit counters, the API-key cache | Every merchant gets a fresh budget for the current minute; keys are looked up again | Themselves, within a minute |
| Circuit-breaker state | A PSP whose breaker was open is called again at full rate | The breaker opens again after the next failures ([#17](DECISIONS.md#17-a-circuit-breaker-per-psp--and-the-one-rule-any-future-failover-must-obey)) |

**Production** (D3 in `docs/plans/2026-10-21-production-readiness.md`; the host is still undecided, D2): the same AOF settings (`appendonly yes`, `appendfsync everysec`) with RDB snapshots kept for backups, `maxmemory-policy noeviction` with a `maxmemory` sized for the queues at their worst backlog plus the cache. Under any other policy an evicted key is a silently lost job; Sidekiq 8 logs a warning at boot (`The 'noeviction' maxmemory policy is recommended`) when the policy is not `noeviction`. With `noeviction`, a full Redis refuses writes instead (`OOM command not allowed`): enqueues fail loudly, the API answers errors, nothing disappears. Alert on `used_memory` approaching `maxmemory` (say 80 %) before that happens. The rate-limit counters and API-key cache (`payhub-cache:` keys) share this Redis; under `noeviction` they still go away by their TTL (a minute or two), not by eviction. If cache memory pressure ever matters, the production option is a separate cache Redis with `allkeys-lru` (`REDIS_URL` for Sidekiq, a second URL for `Rails.cache`); one Redis is fine at today's sizes. And high availability: a replica with automatic failover (Redis Sentinel, or a managed service's Multi-AZ / standard tier). Replication is asynchronous, so a failover can lose the last writes; the sweepers cover lost payment work, so restart the worker after a failover if its cron jobs are missing (`Sidekiq::Cron::Job.all.size` in `bin/rails runner`, 7 today). D3's exit criterion is a tested failover.

## Secrets

**Until D4** (a secrets manager, `docs/plans/2026-10-21-production-readiness.md`), secrets live in environment files on the host that starts the containers, and nowhere else:

- `production.env`, one per environment, made from `production.env.example` (placeholders only; it says which container gets what). Mode `600`, owned by the deploy user, never committed (`.gitignore`: `.env`, `.env.*`, `*.env`, except `*.example`; `git check-ignore production.env` prints the path). Keep a copy where the team's recovery process can reach it: losing `AR_ENCRYPTION_*` makes every stored TOTP secret unreadable.
- `bin/generate-secrets` prints fresh `SECRET_KEY_BASE`, `AR_ENCRYPTION_PRIMARY_KEY`, `AR_ENCRYPTION_DETERMINISTIC_KEY`, `AR_ENCRYPTION_KEY_DERIVATION_SALT`, `METRICS_TOKEN`, `APP_DB_PASSWORD` and `OWNER_DB_PASSWORD` (standard library only). It writes nothing unless given `--append <file>`, which adds only the keys the file lacks (creating it with mode `600`) and never overwrites one; it warns if the file is readable by others.
- Locally, Compose reads `.env` (`.env.example` lists every variable, all with dev defaults). Changing `POSTGRES_PASSWORD` after the `pgdata` volume exists also needs `ALTER ROLE payhub PASSWORD '…'` in `docker compose exec db psql -U payhub`.

**Rotation is manual**: change the value in `production.env`, then restart what reads it.

| Secret | Rotate by |
| --- | --- |
| `SECRET_KEY_BASE` | New value, restart web and worker. Every session cookie becomes invalid: everyone signs in again |
| `AR_ENCRYPTION_*` | Not by replacing them: stored TOTP secrets would become unreadable. Rails' `previous:` keys (config `active_record.encryption.previous`) are needed first; that is part of D4 |
| `METRICS_TOKEN` | New value on web, worker and the collector, restarted together; scrapes get 401 in between |
| `APP_DB_PASSWORD` / `OWNER_DB_PASSWORD` | `ALTER ROLE … PASSWORD` (psql `\password`), then the URLs in `production.env` (and PgBouncer's `auth_file`), then restart web and worker. Existing connections stay up; new ones need the new password |
| PSP webhook secrets | [Rotating a webhook secret](#rotating-a-webhook-secret-not-a-page--planned-work) (two secrets at once, no dropped webhook) |
| PSP API keys, SMTP | New value from the provider, restart web and worker, then revoke the old one at the provider |

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
- **S3 outage.** The 0.111.0 S3 exporter has no queue and no retry: a batch whose upload fails is dropped from the archive (the collector logs an `awss3` export error) but is still in ClickHouse for 90 days. The collector's own metrics are scraped into ClickHouse (job `otelcol`), and `payhub-archive-upload-failed` pages on any failed upload (see [Alerts](#alerts-grafana)). Backfill it from ClickHouse before then, under its own prefix so it is not mistaken for the collector's output:
  `INSERT INTO FUNCTION s3('https://<bucket>.s3.<region>.amazonaws.com/payhub/logs-backfill/<from>_<to>.jsonl.gz', 'JSONEachRow') SELECT Timestamp, ServiceName, SeverityText, Body, LogAttributes FROM otel.otel_logs WHERE Timestamp >= '<from>' AND Timestamp < '<to>'`
- **Long lines.** Docker splits a line over 16KB into chunks; the collector joins them again, up to 1MiB. A line over 1MiB is truncated: the first ~1MiB is kept as one unparsed record (the raw line, with its service but none of its fields) and the rest is dropped. Keep log lines short anyway: never log a body or a payload.
- **Network.** The OTLP receivers (4317, 4318) accept anything sent to them, without authentication. Expose them only on the internal network that web and worker use, never on a public interface.
- **Retention.** The TTL is set when the exporter creates the tables, the same 90 days for logs, traces and metrics. Changing `ttl` later does not alter existing tables; run e.g. `ALTER TABLE otel.otel_logs MODIFY TTL TimestampTime + toIntervalDay(<days>)` (and the same for `otel_traces` and `otel_metrics_*`, whose TTL columns differ: `SHOW CREATE TABLE` first).

The collector cannot refuse to start without a variable, so the deploy must set all of these:

| Variable | What |
|---|---|
| `CLICKHOUSE_ENDPOINT`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` | ClickHouse, e.g. `tcp://clickhouse.internal:9000?dial_timeout=10s` |
| `LOG_ARCHIVE_REGION`, `LOG_ARCHIVE_BUCKET` | The archive bucket. AWS credentials come from the default chain (instance role or `AWS_*`) |
| `WEB_METRICS_TARGET`, `WORKER_METRICS_TARGET` | `host:port` of web's and the worker's `/metrics` (the worker serves on 9394). One container each, never a load-balanced address (see below) |
| `METRICS_TOKEN` | The same value web and worker have. Unset or different, every scrape gets 401: `up` is 0 and the metrics panels go empty |

**One scrape target per container.** Each web and worker container keeps its own metrics, so a target behind a load balancer answers from a different container on each scrape; the counters then seem to drop and rise, and the counter-based alerts page for nothing. The shipped config has one target per service, so it assumes one web and one worker container per host, with a collector on each host. With more containers, list each one's `host:port` in that job's `targets` (`observability/otel-collector.production.yaml`), or use service discovery that returns every container (`docker_sd_configs`, `ecs`/`kubernetes_sd_configs`).

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

## Alerts (Grafana)

Grafana evaluates these every minute from ClickHouse (`observability/grafana/provisioning/alerting/payhub-rules.yaml`). **page** goes to the `payhub-oncall` webhook (`ALERT_WEBHOOK_URL` on Grafana) and wakes someone; **ticket** goes to `payhub-tickets` (`ALERT_TICKET_WEBHOOK_URL`) for the day team. Both are grouped by alert name and repeated every 4 hours while firing. Each notification carries the value the rule saw; each rule's query is in the file as plain SQL: paste it into ClickHouse to see the number now. Which SLO each alert protects, its error budget, and how to measure it by hand are in [docs/SLO.md](docs/SLO.md); the dashboard's **SLOs** row shows those alerts' queries as they run now.

- **Windows outlast the incident.** A rule fires while its window holds the rise: `payhub-recon-breaks` and `payhub-ledger-imbalance` stay firing for 24 hours after one event (and repeat every 4 hours). A second event in that time does not fire again; it only raises the value, so compare the notification's value with the last one.
- **Cold starts do not page.** On the collector's first deploy, after ClickHouse loses its volume, or after the collector was down for over a day, every counter reappears at once; its first value is taken as the baseline, not a rise. A counter that rose during that gap is not seen: after such a gap, check the log for `late_success`, `alert.stuck_payment`, `settlement.discrepancy` and `ledger_imbalance` lines over it.

| Alert (uid) | Severity | Fired because | Start at |
|---|---|---|---|
| <a id="payhub-late-success"></a>`payhub-late-success` | page | A PSP reported `authorized`/`captured` for a payment we had already failed (`webhook.late_success` in the worker log). The customer may be charged for an order the merchant was told failed; nothing was booked. | [§7](#7-money-questions-did-the-customer-get-charged) to confirm the charge with the PSP ([§4](#4-the-psp-knows-the-answer-and-we-dont)), then the payment waits in `/ops` for a refund. Do not move it out of `failed`. |
| <a id="payhub-psp-never-received"></a>`payhub-psp-never-received` | ticket | The sweeper failed a Kiripay payment as `psp_never_received` after 30 minutes. | [§4](#4-the-psp-knows-the-answer-and-we-dont) "404 — the PSP has never seen it". If the charge turns up later, it arrives as a late success. |
| <a id="payhub-audit-write-failed"></a>`payhub-audit-write-failed` | page | An authorization refusal could not be written to the audit log (`audit_refusal_failed` in the web log). The audit trail has a gap. | The log line's `error` and `detail`; usually the database. [§5](#5-it-is-our-bug) if it is not an outage. |
| <a id="payhub-psp-call-in-tx"></a>`payhub-psp-call-in-tx` | ticket | A PSP call was made inside an open database transaction (DECISIONS #13): a rollback would lose the record of a call the PSP received. | [§5](#5-it-is-our-bug): the `psp_call` log line names the PSP and path; the fix is code. |
| <a id="payhub-circuit-open"></a>`payhub-circuit-open` | page | A PSP's circuit breaker opened (`psp_circuit.opened`): PayHub stopped calling it for 30 seconds at a time. | [§3](#3-psp-unreachable). |
| <a id="payhub-recon-breaks"></a>`payhub-recon-breaks` | ticket | The settlement run found lines that do not match the ledger. | [Settlement discrepancies](#settlement-discrepancies-the-morning-after). |
| <a id="payhub-ledger-imbalance"></a>`payhub-ledger-imbalance` | page | Reconciliation found a transfer that does not net to zero. | [§7](#7-money-questions-did-the-customer-get-charged) "Every `transfer_id` must net to zero"; page the day team. |
| <a id="payhub-stuck-alerts"></a>`payhub-stuck-alerts` | page | The sweeper raised `alert.stuck_payment`: a payment in `pending` or `unknown` for more than 15 minutes. | The top of this runbook, [§1](#1-find-the-payment-30-seconds). |
| <a id="payhub-stuck-unknown"></a>`payhub-stuck-unknown` | page | `payhub_unknown_state_payments` (from web) has been above 0 for 15 minutes. | [§2](#2-decide-which-of-four-situations-you-are-in-1-minute); find them with `Payment.where(state: "unknown")`. |
| <a id="payhub-dead-letters"></a>`payhub-dead-letters` | ticket | `payhub_outbound_events_dead` (from web) is above 0: merchant webhooks that ran out of retries. | [Quick reference](#quick-reference) "What did we tell the merchant?"; redeliver once the merchant's endpoint is fixed. |
| <a id="payhub-error-spans"></a>`payhub-error-spans` | page | More than 2% of requests and jobs (server and consumer spans, at least 20 in 5 minutes, `/metrics` and `/healthz` left out) ended in error, for 5 minutes. Jobs count in the ratio too: a burst of failing jobs pages as well. | Grafana Explore on `otel_traces` with `StatusCode = 'Error'` to see which route or job; then [§3](#3-psp-unreachable) (PSP), [§6](#6-the-job-never-ran) (Sidekiq) or [§5](#5-it-is-our-bug). |
| <a id="payhub-slo-api-p95"></a>`payhub-slo-api-p95` | ticket | The p95 of `/v1` request duration, over the last 10 minutes, has been above 300ms for 10 minutes. | The slowest `/v1` traces in Grafana; a slow PSP shows as long client spans ([§3](#3-psp-unreachable)). |
| <a id="payhub-slo-outcome"></a>`payhub-slo-outcome` | page | Payments have stayed in `unknown` for the whole hour (`payhub_unknown_state_payments` from web above 0 throughout): the payment outcome SLO is burning. Stuck-payment alerts page on their own (`payhub-stuck-alerts`). | [§1](#1-find-the-payment-30-seconds), then [§2](#2-decide-which-of-four-situations-you-are-in-1-minute). |
| <a id="payhub-scrape-down"></a>`payhub-scrape-down` | page | The collector has not scraped the labelled `service` (`payhub-web` or `payhub-worker`) for 5 minutes (`up` = 0, or no scrape at all); one alert per service. Every metric alert for it is blind. | Is the service up (`docker compose ps`, [§6](#6-the-job-never-ran) for the worker)? If it is, `METRICS_TOKEN` differs between it and the collector ([Logs and retention](#logs-and-retention), the variable table). |
| <a id="payhub-logs-silent"></a>`payhub-logs-silent` | page | No PayHub log line reached ClickHouse in 15 minutes. The sweepers log every minute, so this is the pipeline, and the S3 archive has the same gap. | The collector's own logs, then [Logs and retention](#logs-and-retention) (`env: OTEL_SERVICE_NAME`, permissions, restarts). |
| <a id="datasource-error"></a>`DatasourceError` (any rule) | the rule's | Grafana could not run a rule's query: ClickHouse is unreachable, refused the login, or rejected the SQL. The alert names the rule (`rulename`) and carries the error. While it fires that rule is blind; when every rule errors, all alerting is. | `docker compose ps clickhouse` and `curl -s localhost:8123/ping` (production: the ClickHouse host Grafana's datasource points at); then Grafana → Connections → ClickHouse → *Save & test*. If only one rule errors, paste its SQL into ClickHouse to see the error; a ClickHouse upgrade can reject a function the rule uses. Until it clears, watch the log and the `/ops` queue by hand. |
| <a id="payhub-archive-upload-failed"></a>`payhub-archive-upload-failed` | page | The collector failed to upload log records to S3 (`otelcol_exporter_send_failed_log_records`, exporter `awss3`). The 0.111.0 exporter does not retry: those lines are not in the archive. | [Logs and retention](#logs-and-retention) "S3 outage": fix the bucket or credentials, then backfill the hour from ClickHouse. |

## Quick reference

| Question | Where |
|---|---|
| What happened to payment X? | `grep '"payment_id":"X"' log/*.log` — one line per request and job |
| What state, and how did it get there? | `payment_transitions` ordered by `sort_key` |
| Did money move? | `ledger_entries` for the payment |
| What did the PSP tell us? | `inbound_events` (`signature_valid=false` rows were rejected, never processed) |
| What did we tell the merchant? | `outbound_events` + `outbound_delivery_attempts`; `POST /v1/events/:id/redeliver` for dead ones. Retries back off 1m, 5m, 30m, 2h, 8h, 24h, 36h; dead after attempt 8 (~70.6h). A redelivery gets a fresh 8-attempt budget on the same schedule; attempt numbers continue from where they stopped |
| Backlog right now | `/metrics`: `payhub_unknown_state_payments`, `payhub_outbound_events_pending`, `payhub_outbound_events_dead` |
| Which database user? | Web and worker: `payhub_app` (rows only; cannot touch the triggers). The migration container only: `payhub_owner`, via its own `DATABASE_URL`. `permission denied for table …` after a deploy: something was created by another role; rerun `db/roles.sql` as a superuser. [Database roles](#database-roles-planned-work-before-the-first-deploy-with-them) |
| Migrate on deploy | One one-off container from the new image: `bin/rails db:prepare` as a release task, or `RUN_MIGRATIONS=true` with the command `true` (the entrypoint migrates, then `true` exits); web (`CMD`, Puma) and worker (`bundle exec sidekiq`) without it, and the entrypoint refuses it with a server command. Its `DATABASE_URL` is the owner URL ([Database roles](#database-roles-planned-work-before-the-first-deploy-with-them)) pointing at Postgres itself or a session-mode pool, never a transaction-mode PgBouncer (the migration's session `SET`s would leak into app traffic, and its advisory lock would not hold; [Connection pooling](#connection-pooling-pgbouncer)). README "Production image" |
| Connection pool | Web and worker through PgBouncer (transaction mode), `db:` tasks direct (`MIGRATION_DATABASE_URL`). `SHOW POOLS` on the admin console: `docker compose exec pgbouncer psql -h localhost -p 6432 -U payhub pgbouncer -c 'SHOW POOLS'`; `cl_waiting` above 0 means `default_pool_size` is too small. No session `SET`s or session advisory locks through it. [Connection pooling](#connection-pooling-pgbouncer) |
| <a id="safe-migrations"></a>Safe migrations (strong_migrations blocked one) | The error names the operation and prints the safe version; use it. Indexes: `disable_ddl_transaction!` plus `algorithm: :concurrently` (a failed concurrent build leaves an INVALID index; rerunning the same `add_index :table, :columns, …` drops it first, automatically; for any other form, such as an `execute`d `CREATE INDEX`, `DROP INDEX CONCURRENTLY` it by hand before rerunning). `safety_assured { … }` only with a comment in the migration saying why it is safe. `canceling statement due to lock timeout` on deploy: something held the table for over 10 s. A migration in a transaction (the default) rolled back whole; one with `disable_ddl_transaction!` kept the steps before it, so check which ran. Rerun it when traffic is lower, on Postgres directly or a session-mode pool, never a transaction-mode PgBouncer ("Migrate on deploy"). README "Migrations" |
| Puma workers and database connections | `WEB_CONCURRENCY` worker processes per web container (cluster mode from 1, the app preloaded from 2; use 0 or at least 2, Puma warns about a single worker; the boot log says `Puma starting in cluster mode` and `Workers: N`) × `RAILS_MAX_THREADS` threads (default 3; the DB pool defaults to 5, so set it explicitly on web, and on the worker keep it at least the Sidekiq concurrency). Connections at most: web containers × `WEB_CONCURRENCY` × threads + worker containers × Sidekiq concurrency (5) + headroom for one-off tasks (migrations, consoles); size Postgres or PgBouncer for it ([Connection pooling](#connection-pooling-pgbouncer) "Sizing"). README "Configuration" |
| <a id="stop-grace-periods"></a>Stop grace periods | Web: the platform's stop grace above Puma's `worker_shutdown_timeout` (25 s, cluster mode only; in single mode, `WEB_CONCURRENCY` unset or `0`, Puma waits for requests with no limit, so the grace period is the only bound); worker: at least Sidekiq's `:timeout:` (25 s) + 5 s. ECS/Kubernetes default 30 s, Docker 10 s (Compose sets 30 s web, 35 s worker). Deregister from the load balancer before SIGTERM (ALB deregistration delay, Kubernetes `preStop` sleep): Puma closes its listeners at once. Keep `persistent_timeout` (65 s) above the ALB idle timeout (60 s). A worker SIGKILLed mid-drain loses the jobs it was running (already popped from Redis, no retry). README "Configuration" |
| Boot without TLS (debugging the image) | `RAILS_FORCE_SSL=false`; never behind a real host |
| Job counters (late success, stuck-payment alerts, settlement discrepancies, PSP call in transaction) | The worker's own `/metrics` on port 9394 (`WORKER_METRICS_PORT`), same bearer token; not in the web scrape. `docker compose exec worker curl -s -H "Authorization: Bearer $METRICS_TOKEN" localhost:9394/metrics`. In ClickHouse: `ServiceName = 'payhub-worker'` (web is `'payhub-web'`) |
