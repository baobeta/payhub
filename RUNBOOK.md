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
- **404 — the PSP has never seen it:** the request never landed. The sweeper will re-send **with the same `psp_reference`** on its next pass (this is the only re-send in the system, and only after a confirmed 404). Let it.
- **Kiripay returns two charges for one reference:** the earliest is the real one and the sweeper uses it. The later one is a duplicate Kiripay created for a retried request; the daily reconciliation flags it. Do not refund it from this runbook — hand it to the day team.

## 5. It is our bug

Symptoms: `sweeper.skip` with `PspAdapter::Rejected`, or `webhook.illegal_transition`, or an exception in the worker log.

1. Read the exception. `Rejected` carries the PSP's HTTP status and message; `IllegalTransition` names the edge (`from -> to`).
2. **Do not** hand-edit `payments.state`. It is not writable — `Payment#state=` raises — and even if you got around it, the history and the ledger would disagree with the PSP.
3. If you must move the payment tonight (merchant escalation) and the PSP's view is unambiguous, the honest operator action is a transition with `source: "operator"` and the reason in metadata, from a console:
   ```ruby
   p = Payment.find("<PAYMENT_ID>")
   p.transition!(:failed, sort_key: Time.current, source: "operator", metadata: { "reason" => "PSP confirms declined; ticket OPS-123" })
   ```
   Only `unknown -> failed` and `unknown -> authorized` exist from `unknown`. There is deliberately no `unknown -> canceled`: you cannot release a hold you cannot see (DECISIONS #10).
4. Open a ticket with the exception, the `payment_id`, and the PSP response. The fix is code, not data.

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

## A merchant user is locked out (not a page — a support ticket)

Ten wrong passwords or codes lock an account for 30 minutes; it unlocks by itself. If it cannot wait (confirm who is asking, through the merchant's owner):

```ruby
u = MerchantUser.find_by!(email: "<email>")
u.reset_failures!
AuditEvent.record!(action: "user.unlocked_by_support", result: "success", merchant_id: u.merchant_id,
                   target: u, metadata: { "ticket" => "<TICKET-ID>" })
```

Lost phone: they sign in with a recovery code, then regenerate codes on their Profile page. Lost both: an admin or the owner removes them and invites them again (a new invitation means a new authenticator enrolment).

## Quick reference

| Question | Where |
|---|---|
| What happened to payment X? | `grep '"payment_id":"X"' log/*.log` — one line per request and job |
| What state, and how did it get there? | `payment_transitions` ordered by `sort_key` |
| Did money move? | `ledger_entries` for the payment |
| What did the PSP tell us? | `inbound_events` (`signature_valid=false` rows were rejected, never processed) |
| What did we tell the merchant? | `outbound_events` + `outbound_delivery_attempts`; `POST /v1/events/:id/redeliver` for dead ones |
| Backlog right now | `/metrics`: `payhub_unknown_state_payments`, `payhub_outbound_events_pending`, `payhub_outbound_events_dead` |
