# Plan: fix the use-case audit findings

Source: [USE_CASES.md](../USE_CASES.md) §1 (15 bugs) and [TEST_CASES.md](../TEST_CASES.md).
Baseline: 722 examples, 0 failures, on master `8115c67`.

**Rule for every item:**
1. Write the TC spec first and watch it fail for the reason the TC states.
2. Write the smallest fix.
3. The full suite stays green.
4. Update the DECISIONS/DOMAIN text the fix changes.

## Phase 1: fixes, in three parallel lanes

Each lane runs in its own worktree with its own `TEST_DATABASE`.

### Lane A: money movement (capture, refund, cancel, inbound webhooks)

| Bug | TCs | Change |
| --- | --- | --- |
| 3: multicapture | TC-E3-1…19 | Add migration `payments.captures_closed_at` and `captures.final` (default true), and backfill closed for captured/part_refunded/refunded. Capture runs from `authorized`/`captured`/`part_refunded` while capturing is open. Add the `final` param, close-on-0, `capture_closed`, `multicapture_unsupported` and `capture_limit_reached` (50). `supports_multicapture?` is a new adapter capability. The refund job becomes `refunded` only when closed and fully refunded. ExpireAuthorizationsJob closes open remainders. Add the `capture.succeeded`/`capture.failed`/`payment.captures_closed` events. PaymentActions, the serializer (`amount_capturable_minor`) and the CaptureDialog text change. The simulation issues non-final captures and counts refusals. |
| 14 | TC-E11-1/2, TC-E3-15 | The webhook books the PSP-reported `captured_minor` when present; otherwise the full amount. A Nordpay "authorized with captured_minor" event on a captured payment books progress and never transitions. |
| 2 | TC-BUG2-1/2 | `RefundPaymentJob` rescues `Rejected` and goes down the failed path (void the reservation, `refund.failed`). |
| 6 | TC-G6-1…4 | `supports_void?` capability (Nordpay true, Kiripay false). A preflight 400 `cancel_unsupported`. `rescue_from Rejected` → 409 `psp_rejected` in the v1 and dashboard controllers. The expiry job skips PSPs that can't void. |
| 4b | TC-B3-3 | A capture webhook on a `failed` payment logs `webhook.late_success_after_failure` and sends a metric. The payment goes into the ops queue. |

**Docs:**
- DECISIONS #20 (multicapture semantics, market refs)
- DECISIONS #14 (remainder closing)
- DECISIONS #9 (new capabilities)
- the DOMAIN.md captures section, and walkthrough step 9

### Lane B: recovery (authorize, sweeper, orphans)

| Bug | TCs | Change |
| --- | --- | --- |
| 1 | TC-B7-1…4, TC-B8-1/2 | New adapter capability `idempotent_authorize?` (Nordpay true, Kiripay false). For a non-idempotent PSP, never re-POST once `first_sent_at` is set: the job and the sweeper resolve by `fetch`. When NotFound lasts longer than `KIRIPAY_LOOKUP_GRACE` (30 min), the payment goes to `failed` with `psp_never_received`. |
| 4 | TC-B3-1/2/4 | The sweeper watches `requires_action` older than `REQUIRES_ACTION_TIMEOUT` (30 min). It fetches, then applies the result or fails with `customer_action_expired`. |
| 15 | TC-D5-1…3 | Orphan re-drive covers the last 24h, split half oldest and half newest. Older orphans are closed with an error and logged `webhook.orphan_abandoned`. |
| 12 | TC-C4-1 | A real-thread race spec. Rewrite DECISIONS #7 to describe `with_lock`, and remove the dead StaleObjectError rescue. |

**Docs:** DECISIONS #12 (the never-re-POST rule now enforced, plus the grace window), #7 and #13.

### Lane C: platform, books, audit

| Bug | TCs | Change |
| --- | --- | --- |
| 5 | TC-L3-1…3 | Roll only keys that are `active` and not already expiring. Otherwise 409. |
| 7 | TC-H4-1/2 | Migration `outbound_events.attempt_budget` (default 8). `redeliver!` sets budget = attempts + 8. Dead when attempt ≥ budget. |
| 8 | TC-I2-1…4 | Migration: an append-only trigger on `payment_transitions` that allows only the `most_recent` true→false flip, plus a TRUNCATE guard on `payment_transitions` and `ledger_entries`. |
| 9 | TC-J3-1…3, TC-J4-1, TC-J1-2 | Validate net = gross − fee before booking. Rescue `Unbalanced` per line. A refund already settled by another line → mismatch. Tell external-id duplicates apart from refund-leg conflicts. |
| 10 | TC-M14-1…3, TC-N17-1 | Audit mutating requests that end in an ApiError (4xx except 401 unauthenticated) as result `failure`/`denied`, with the code. This applies to the dashboard and ops base controllers. |
| 11 | TC-N7-1/2 | Another operator's token → 409 `client_token_in_use`. Rescue RecordNotUnique. |
| 13 | TC-A14-1/2 | Refuse a Luhn-valid 13–19 digit token. Update the PAN spec. |

**Docs:** the DOMAIN.md "written in pen" list, the RUNBOOK note on redeliver, and the API docs for the new error codes.

## Merge

- Merge the lanes into `fix/use-case-coverage`.
- Lanes A and C both add migrations: re-run `db:migrate` to regenerate `db/structure.sql`. Resolve the adapter-capability hunks from lanes A and B.
- Run the full suite, Sorbet (`bin/check` if present) and the linter.
- Then an independent review pass (code-reviewer agent). That pass doesn't author fixes.

## Phase 2: fill the remaining test gaps (TEST_CASES §3)

Specs only, split by spec directory so the agents don't collide. The work runs after the merge.

## Out of scope (recorded, not built)

- the market items in USE_CASES §9
- releasing the remainder at the PSP (G5)
- automatic refund of late wallet successes (M-4)
