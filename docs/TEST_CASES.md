# PayHub test cases

> The test cases behind [USE_CASES.md](USE_CASES.md). Each case has:
> - **Situation:** what is true before, and what happens.
> - **Expected:** what PayHub must do. A spec asserts it.
> - **Ref:** where the rule comes from: our docs, DECISIONS, or a market source.
> - **Spec:** the file the example lives in.
> - **Now:** ✅ passing on `fix/use-case-coverage` · ❌ failing · ➕ no spec yet.
>
> IDs map to USE_CASES.md: `TC-B7-1` tests use case B7. `TC-BUG3-…` tests bug #3 in USE_CASES §1.
>
> **Status (2026-10-20):** every case below has a passing spec. That is 107 TC ids: the 98 listed here plus 9 added by the code review (§4). The full suite is 884 examples, 0 failures, 0 pending. Find a case with `grep -rn "TC-E3-2" spec`.

---

## 1. Fixes: the 15 bugs

### Bug 1: Kiripay is never charged twice (B7, B8)

**TC-B7-1. A Kiripay authorize that timed out is never re-sent after a "not found" lookup**
- **Situation:** A Kiripay payment was sent (`first_sent_at` set) and timed out, so it is `unknown`. The lookup by `merchant_reference` returns no charge, as replica lag can make it do.
- **Expected:** PayHub does **not** POST `/charges` again. The payment stays `unknown` and the sweeper checks again later.
- **Ref:** DECISIONS #12: "never by re-POSTing". Stripe/Adyen: retry only with an idempotency key the PSP honours.
- **Spec:** `spec/services/resolve_unknown_payment_spec.rb` (new) · **Now:** ✅

**TC-B7-2. Nordpay still re-sends after "not found", with the same reference**
- **Situation:** A Nordpay payment is `unknown`. The fetch returns 404.
- **Expected:** One authorize is re-sent with the **same** `psp_reference`. Nordpay deduplicates it by `X-Request-Id`.
- **Ref:** DECISIONS #2, #12.
- **Spec:** `spec/jobs/authorize_payment_job_spec.rb` · **Now:** ✅

**TC-B7-3. A Kiripay 5xx retry looks up before sending**
- **Situation:** The first Kiripay POST returned 503 (`Unavailable`) and the job is retried. Kiripay **did** create the charge.
- **Expected:** The retry calls `fetch` first, finds the charge, and applies it. There is no second POST: `adapter.calls[:authorize].size == 1`.
- **Ref:** DECISIONS #12. A 5xx is not proof the PSP did nothing.
- **Spec:** `spec/jobs/authorize_payment_job_spec.rb` · **Now:** ✅

**TC-B8-1. A crash after the Kiripay call but before the state was saved doesn't double-charge**
- **Situation:** The job sent the Kiripay POST (`first_sent_at` set), then crashed. The payment is still `pending`, and the job runs again.
- **Expected:** The rerun looks up by reference instead of sending. One charge only.
- **Ref:** DECISIONS #12, #2.
- **Spec:** `spec/jobs/authorize_payment_job_spec.rb` · **Now:** ✅

**TC-B8-2. A Kiripay payment that was never sent can be sent**
- **Situation:** A Kiripay payment is `pending` with `first_sent_at` nil. The worker died before the first call.
- **Expected:** The sweeper or job sends the first POST as normal.
- **Ref:** DECISIONS #2 (the reference is saved before the call, so sending once is safe).
- **Spec:** `spec/jobs/stuck_payment_sweeper_job_spec.rb` · **Now:** ✅

**TC-B7-4. A Kiripay charge that never appears ends as failed**
- **Situation:** A Kiripay payment was sent, but every lookup for longer than `KIRIPAY_LOOKUP_GRACE` (30 min) finds nothing.
- **Expected:** The payment goes `unknown`/`pending` → `failed` with `decline_code: "psp_never_received"`. A `payment.failed` event is sent, and the customer is not charged.
- **Ref:** DECISIONS #10 (a state only where we can honestly claim it). Adyen: give a terminal answer when an outcome can't be resolved.
- **Spec:** `spec/services/resolve_unknown_payment_spec.rb` · **Now:** ✅

### Bug 2: a refund the PSP rejects is failed and its money released (F8)

**TC-BUG2-1. Rejected refund → failed, reservation voided, merchant told**
- **Situation:** A €25 captured payment has a €10 refund `pending` (€10 reserved). The PSP answers 4xx (`Rejected`).
- **Expected:**
  - the refund is `failed` with `failure_code: "psp_rejected_<status>"`
  - `Ledger.reserved_minor == 0`
  - the balance is back to €25
  - a `refund.failed` event is written
  - the payment state is unchanged
- **Ref:** DECISIONS #16 (a reservation is posted or voided, exactly once). Stripe `refund.failed`; Adyen REFUND_FAILED: the money returns to the merchant.
- **Spec:** `spec/jobs/refund_payment_job_spec.rb` · **Now:** ✅

**TC-BUG2-2. A Kiripay refund on a charge that can't be found fails cleanly**
- **Situation:** The Kiripay `refund` adapter raises `Rejected(404)` because the charge was not found.
- **Expected:** Same as TC-BUG2-1. The sweeper does **not** re-drive it again.
- **Spec:** `spec/jobs/refund_payment_job_spec.rb` · **Now:** ✅

### Bug 3: several partial captures (E3). See §2, multicapture.

### Bug 4: an abandoned wallet payment ends (B3)

**TC-B3-1. The sweeper watches `requires_action` payments**
- **Situation:** A Kiripay payment has been `requires_action` for longer than `REQUIRES_ACTION_TIMEOUT`.
- **Expected:** The sweeper calls `fetch(psp_reference)`:
  - PSP says `captured` → book the capture and move to `captured`, as if the webhook had arrived.
  - PSP says `declined` → `failed`.
  - PSP still says pending → `failed` with `decline_code: "customer_action_expired"`, plus a `payment.failed` event.
- **Ref:** Stripe/Adyen/Xendit: an abandoned redirect or wallet payment reaches a terminal `expired`/`canceled` state. DECISIONS #10: "abandonment is failed, not ambiguity".
- **Spec:** `spec/jobs/stuck_payment_sweeper_job_spec.rb` · **Now:** ✅

**TC-B3-2. A fresh `requires_action` payment is left alone**
- **Situation:** A payment has been `requires_action` for 2 minutes.
- **Expected:** The sweeper makes no PSP call and does not change the state.
- **Spec:** same · **Now:** ✅

**TC-B3-3. A late success after a local expiry is not lost**
- **Situation:** A payment was failed locally as `customer_action_expired`. Then a Kiripay `charge.captured` webhook arrives.
- **Expected:**
  - the event is stored and marked processed with an error
  - an ERROR log `webhook.late_success_after_failure` is written
  - the `late_success` metric is incremented
  - the payment appears in the ops queue
  - no state regression and no booking
  - a human then refunds it
- **Ref:** Xendit (success-only callbacks); market list M-4. Automatic refunds are out of scope for now.
- **Spec:** `spec/jobs/process_inbound_event_job_spec.rb` (new) · **Now:** ✅

**TC-B3-4. A Kiripay decline webhook moves `requires_action` → `failed`**
- **Situation:** A payment is `requires_action`. A Kiripay `charge.declined` webhook arrives.
- **Expected:** The payment is `failed` with `decline_code: "wallet_declined"`, and a `payment.failed` event is sent.
- **Spec:** `spec/requests/v1/webhooks_spec.rb` · **Now:** ✅

### Bug 5: an expired API key can't be revived (L3)

**TC-L3-1. Rolling an expired key is refused**
- **Situation:** A key's `expires_at` is in the past. An admin POSTs roll on it.
- **Expected:** 409 `invalid_state` ("only active keys can be rolled"). The old key's `expires_at` is unchanged, no new key is issued, and an API call with the old key still returns 401.
- **Ref:** Stripe: an expired key stays dead. PCI 8.3: revoked credentials can't be reused.
- **Spec:** `spec/requests/dashboard/api/api_keys_spec.rb` · **Now:** ✅

**TC-L3-2. Rolling a revoked key is refused**
- Same as TC-L3-1, but for a revoked key. · **Now:** ✅

**TC-L3-3. Rolling an active key twice inside its overlap**
- **Situation:** Key A is rolled to B (A expires in 24h). Then A is rolled again.
- **Expected:** A is no longer "active-for-roll" once it has an `expires_at` set by a roll, so 409. B can be rolled.
- **Ref:** Stripe: rolling key #1 twice is refused; roll the new key.
- **Spec:** same · **Now:** ✅

### Bug 6: a cancel the PSP refuses returns a clear 4xx (G2, G6)

**TC-G6-1. Kiripay cancel is refused up front**
- **Situation:** POST `/v1/payments/:id/cancel` on an `authorized` Kiripay payment.
- **Expected:** 400 `cancel_unsupported`, with no PSP call. The adapter declares `supports_void? == false`.
- **Ref:** DECISIONS #9 (adapters declare capabilities; the domain enforces them).
- **Spec:** `spec/requests/v1/money_movement_spec.rb` · **Now:** ✅

**TC-G6-2. Nordpay 409 `not_voidable` becomes a 4xx**
- **Situation:** Nordpay answers 409 on void, so the adapter raises `Rejected(409)`.
- **Expected:** API 409 `psp_rejected`, `retriable: false`. The payment is unchanged.
- **Spec:** same · **Now:** ✅

**TC-G6-3. The dashboard shows no cancel button for Kiripay**
- **Situation:** `PaymentActions` runs for an authorized Kiripay payment.
- **Expected:** `"cancel" => false`.
- **Spec:** `spec/services/payment_actions_spec.rb` · **Now:** ✅

**TC-G6-4. Auto-expiry skips PSPs that can't void**
- **Situation:** A Kiripay payment has been `authorized` and idle for 7 days.
- **Expected:** `ExpireAuthorizationsJob` doesn't call cancel. It logs `authorization.expiry_unsupported` once.
- **Spec:** `spec/jobs/expire_authorizations_job_spec.rb` · **Now:** ✅

### Bug 7: a redelivered dead event gets a full new retry budget (H4)

**TC-H4-1. Redeliver gives 8 more attempts**
- **Situation:** An event is `dead` after 8 attempts. Ops redelivers it, and the merchant endpoint keeps failing.
- **Expected:**
  - the event stays `pending` with backoff
  - it is dead-lettered again only after **attempt 16**
  - attempt numbers continue at 9, 10, … (they stay unique per event)
- **Ref:** Stripe: a manual resend is a fresh delivery with its own retries.
- **Spec:** `spec/jobs/deliver_outbound_events_job_spec.rb` · **Now:** ✅

**TC-H4-2. Redeliver then success → delivered**
- **Situation:** A redelivered event, and the merchant answers 200.
- **Expected:** `delivered`, with `delivered_at` set.
- **Spec:** same · **Now:** ✅

### Bug 8: payment history is append-only in the database (I2)

**TC-I2-1. The DB refuses UPDATE of a transition**
- **Situation:** Raw SQL `UPDATE payment_transitions SET to_state='failed'`.
- **Expected:** `ActiveRecord::StatementInvalid` from the trigger.
- **Ref:** DOMAIN.md "the database refuses edits and deletes"; PCI 10.3.2.
- **Spec:** `spec/models/payment_transition_spec.rb` (new) · **Now:** ✅

**TC-I2-2. The DB refuses DELETE and TRUNCATE of transitions**
- Same as TC-I2-1. · **Now:** ✅

**TC-I2-3. The one allowed change still works**
- **Situation:** A new transition flips the previous row's `most_recent` from true to false.
- **Expected:** Allowed. Flipping false → true, or changing any other column in the same statement, is refused.
- **Spec:** same · **Now:** ✅

**TC-I2-4. `ledger_entries` refuses TRUNCATE**
- **Situation:** `TRUNCATE ledger_entries`.
- **Expected:** The statement is refused.
- **Spec:** `spec/services/ledger_spec.rb` · **Now:** ✅

### Bug 9: settlement mismatches are flagged, never booked or lost (J3, J4)

**TC-J3-1. net ≠ gross − fee is flagged, and the run continues**
- **Situation:** A capture line has gross 2500, fee 45 and net 2400. A second, good line follows it.
- **Expected:**
  - line 1 is `mismatch` with the problem "net 2400 ≠ gross 2500 − fee 45" and no ledger rows
  - line 2 is matched and booked
  - the job does not raise
- **Ref:** DECISIONS #18 ("never fixes money, makes it loud").
- **Spec:** `spec/jobs/settlement_reconciliation_job_spec.rb` · **Now:** ✅

**TC-J3-2. Currency mismatch**
- **Situation:** A line in GBP for a EUR payment.
- **Expected:** `mismatch`, not booked.
- **Spec:** same · **Now:** ✅

**TC-J3-3. Refund amount mismatch**
- **Situation:** A refund line of €9 for a €10 refund.
- **Expected:** `mismatch`, not booked.
- **Spec:** same · **Now:** ✅

**TC-J4-1. A second distinct line for an already-settled refund is a mismatch, not a "duplicate"**
- **Situation:** Line `L1` settles refund R. A later line `L2`, with a different external id, also settles R.
- **Expected:** `L2` is stored as `mismatch` ("refund already settled by L1"). It is not booked and it is counted.
- **Spec:** same · **Now:** ✅

**TC-J1-2. Several capture lines for one payment (multicapture) each settle**
- **Situation:** Payment €25, captures of €10 then €15. Each line settles separately.
- **Expected:** Both lines are matched. Receivable is 0 after the second.
- **Ref:** Adyen/Stripe: each capture is its own settlement line.
- **Spec:** same · **Now:** ✅

### Bug 10: refusals are audited (M14, N17)

**TC-M14-1. A business-rule refusal on the dashboard is audited**
- **Situation:** A support user refunds more than is refundable, which returns 422.
- **Expected:**
  - one `audit_events` row: action `payments.refund`, result `failure`, metadata `{code, http_status}`
  - no request body
- **Ref:** PCI DSS 10.2.1 (log access attempts and failures); DOMAIN.md audit rules.
- **Spec:** `spec/requests/dashboard/api/payments_spec.rb` · **Now:** ✅

**TC-N17-1. Ops self-approve / double-approve / withdraw refusals are audited**
- **Situation:** The proposer tries to approve their own proposal, which returns 409.
- **Expected:** An audit row with result `failure` and code `refused`.
- **Spec:** `spec/requests/ops/api/proposals_spec.rb` · **Now:** ✅

**TC-M14-2. Reads and 401s are not audited**
- **Situation:** A GET that 404s, and an anonymous POST that returns 401.
- **Expected:** No audit row. The table must not fill up with anonymous traffic.
- **Spec:** same · **Now:** ✅

**TC-M14-3. The step-up requirement is audited once**
- **Situation:** A sensitive POST without a fresh code returns 401 `step_up_required`.
- **Expected:** An audit row with result `denied` and code `step_up_required`.
- **Spec:** `spec/requests/dashboard/api/payments_spec.rb` · **Now:** ✅

### Bug 11: a proposal token reused by another operator returns 409 (N7)

**TC-N7-1. Operator B reuses operator A's `client_token`**
- **Situation:** A created a proposal with token T. B POSTs a proposal with token T.
- **Expected:** 409 `client_token_in_use`. No new row, and no 500.
- **Spec:** `spec/requests/ops/api/proposals_spec.rb` · **Now:** ✅

**TC-N7-2. Two submits of the same token at the same time**
- **Situation:** Two threads, same operator, same token.
- **Expected:** One row. Both responses return it (201 and 200).
- **Spec:** same · **Now:** ✅

### Bug 12: DECISIONS #7 matches the code

**TC-C4-1. Sweeper vs webhook on the same payment**
- **Situation:** The sweeper resolves `unknown → authorized` while a webhook applies `authorized` at the same moment (two threads).
- **Expected:** One `authorized` transition. No error escapes, and one `payment.authorized` event.
- **Ref:** DECISIONS #7, rewritten to describe `with_lock` and "already there is fine".
- **Spec:** `spec/jobs/stuck_payment_sweeper_job_spec.rb` · **Now:** ✅

### Bug 13: a card number is refused as a token (A14)

**TC-A14-1. A Luhn-valid 13–19 digit token is refused**
- **Situation:** POST `/v1/payments` with `payment_method_token: "4242 4242 4242 4242"`. Spaces and dashes are allowed in the input.
- **Expected:** 422 on `payment_method_token` ("looks like a card number; send a token"). No payment row. The PAN never appears in the logs or `idempotency_keys.response_body`.
- **Ref:** PCI DSS 3.3/3.4 (never store a PAN in clear text); Stripe rejects a raw PAN on the API by default.
- **Spec:** `spec/requests/v1/pan_never_logged_spec.rb` · **Now:** ✅

**TC-A14-2. Normal tokens still pass**
- **Situation:** Tokens `tok_visa`, `wallet_abc123`, and a 16-digit number that fails Luhn.
- **Expected:** 202.
- **Spec:** same · **Now:** ✅

### Bug 14: a capture webhook books the PSP's amount (E11)

**TC-E11-1. A Nordpay capture webhook after a partial capture books the partial amount only**
- **Situation:** €25 is authorized. We captured €10, and the ledger holds 1000. Nordpay's webhook arrives with `captured_minor: 1000`.
- **Expected:** Nothing more is booked: the ledger stays at 1000.
- **Ref:** DECISIONS #20 ("book from the PSP's running total").
- **Spec:** `spec/jobs/process_inbound_event_job_spec.rb` · **Now:** ✅

**TC-E11-2. A Kiripay capture webhook with no amount books the full amount**
- **Situation:** A Kiripay `charge.captured` webhook. Kiripay is full-capture only.
- **Expected:** `payment.amount_minor` is booked, once.
- **Spec:** `spec/requests/v1/webhooks_spec.rb` · **Now:** ✅

### Bug 15: orphan webhooks don't starve, and finally stop (D5)

**TC-D5-1. An orphan is applied once its payment exists**
- **Situation:** A webhook arrives for reference R before the payment exists. Then the payment is created, and the sweeper runs.
- **Expected:** The event is processed and the payment state has moved.
- **Spec:** `spec/jobs/stuck_payment_sweeper_job_spec.rb` · **Now:** ✅

**TC-D5-2. Old orphans don't block new ones**
- **Situation:** BATCH + 5 orphans from 2 days ago, plus 1 orphan from 2 minutes ago.
- **Expected:** The new orphan is re-driven in this sweep.
- **Ref:** DECISIONS #13 (the same backlog bug fixed for payments).
- **Spec:** same · **Now:** ✅

**TC-D5-3. An orphan older than 24h is closed**
- **Situation:** An orphan received 25h ago, still with no payment.
- **Expected:** Marked processed with error `orphan: no payment for reference`, plus an ERROR log `webhook.orphan_abandoned`. It is not re-driven again.
- **Spec:** same · **Now:** ✅

---

## 2. Multicapture: several partial captures (E2–E6, bug 3)

**How the market does it:**
- **Stripe** (`final_capture`, default **true**): the payment stays capturable after a non-final capture. `amount_capturable` goes down, and a final capture releases the remainder. `amount_to_capture=0, final_capture=true` releases without capturing more. Limit: 50 non-final captures plus 1 final. Refunds are allowed between captures, up to `received − refunded`, and don't change `amount_capturable`. It is "fully refunded" only after the final capture. Sources: [Stripe multicapture](https://docs.stripe.com/payments/multicapture), [capture API](https://docs.stripe.com/api/payment_intents/capture).
- **Checkout.com**: `capture_type` defaults to `Final`. `NonFinal` keeps the rest open. Source: [Checkout.com capture](https://www.checkout.com/docs/payments/manage-payments/capture-a-payment).
- **Adyen**: one CAPTURE webhook per capture. With multiple partial captures the remainder is **not** auto-cancelled; the merchant cancels it, or it expires. Source: [Adyen capture](https://docs.adyen.com/online-payments/capture).
- **PayPal**: `PARTIALLY_CAPTURED`, and `final_capture` defaults to false. Source: [PayPal capture](https://developer.paypal.com/docs/api/payments/v2/#authorizations_capture).
- **Payment methods:** multicapture is card-only. Wallets don't support it.

**What PayHub does (it follows Stripe and Checkout.com, the default most merchants know):**
- `POST /v1/payments/:id/capture` accepts `final` (boolean). The default is **true**, so a plain partial capture behaves exactly as it does today.
- After the first capture lands, the payment moves to `captured`, because money moved, which is an honest claim (DECISIONS #10). It stays **open for more captures** while `final` was false and money remains.
- A final capture **closes** capturing (`payments.captures_closed_at`). `amount_minor: 0, final: true` closes capturing without moving money.
- The uncaptured remainder lapses at the network. Actively releasing it at the PSP is still a non-goal (DECISIONS #14, G5). The hold it leaves is documented; PayHub never pretends to have released it.
- Refunds are allowed between captures. A payment becomes `refunded` (terminal) only when capturing is closed **and** refunded = captured.
- The idle-expiry job (6 days) closes an open remainder on a partly captured payment, instead of voiding it.
- Capabilities: `supports_multicapture?` is true for Nordpay and false for Kiripay.
- Each capture gets its own outbound event, `capture.succeeded` or `capture.failed`. `payment.captured` stays one-per-payment, on the first booking.

**TC-E3-1. A non-final partial capture leaves the payment capturable**
- **Situation:** €25 authorized. `capture {amount_minor: 1000, final: false}` succeeds.
- **Expected:**
  - state `captured`, `captured_minor` 1000, `captures_closed_at` nil
  - `PaymentActions` shows `capture: true`, `capturable_minor: 1500`
  - `GET /v1/payments/:id` shows `amount_capturable_minor: 1500`
- **Ref:** Stripe MC (stays capturable, `amount_capturable` goes down).
- **Spec:** `spec/requests/v1/money_movement_spec.rb` · **Now:** ✅

**TC-E3-2. A second capture after a non-final one is accepted, through the API**
- **Situation:** Following TC-E3-1, `capture {amount_minor: 1500}` is sent (final by default).
- **Expected:**
  - 202, and the job books it: ledger captured 2500
  - two Capture rows, both succeeded
  - `captures_closed_at` is set
  - the payment state is still `captured`
- **Ref:** DECISIONS #20; Stripe MC.
- **Spec:** same · **Now:** ✅

**TC-E3-3. A default (final) partial capture closes capturing, as today**
- **Situation:** €25 authorized. `capture {amount_minor: 1000}` with no `final` succeeds. Then `capture {amount_minor: 500}` is sent.
- **Expected:** The second request gets 400 `capture_closed` ("the final capture has been made"). Ledger captured stays 1000.
- **Ref:** Stripe/Checkout.com default `final=true`.
- **Spec:** same · **Now:** ✅

**TC-E3-4. The sum of captures can never exceed authorized**
- **Situation:** €25 authorized. `capture 1000 final:false`, then `capture 2000`.
- **Expected:** 422 on `amount_minor` ("must be between 1 and 1500"). Nothing is sent to the PSP.
- **Ref:** Adyen "Insufficient balance on payment"; Stripe.
- **Spec:** same · **Now:** ✅

**TC-E3-5. Zero-amount final capture closes the remainder**
- **Situation:** After a non-final €10 capture, `capture {amount_minor: 0, final: true}` is sent.
- **Expected:**
  - 200, with no PSP call and no Capture row
  - `captures_closed_at` set and `capturable_minor` 0
  - audit and event `payment.captures_closed`
- **Ref:** Stripe `amount_to_capture=0, final_capture=true`.
- **Spec:** same · **Now:** ✅

**TC-E3-6. Zero amount on a payment with nothing captured is refused**
- **Situation:** An `authorized` payment with 0 captured. `capture {amount_minor: 0, final: true}` is sent.
- **Expected:** 400 `invalid_request` ("nothing captured; use cancel to release the hold").
- **Spec:** same · **Now:** ✅

**TC-E3-7. One capture in flight at a time still holds**
- **Situation:** `capture 1000 final:false` is pending. A second capture is sent.
- **Expected:** 409 `capture_in_progress`, `retriable: true`.
- **Ref:** DECISIONS #20.
- **Spec:** same · **Now:** ✅

**TC-E3-8. Refund between captures**
- **Situation:** `capture 1000 final:false` succeeded. Then `refund 400`, then `capture 1500`.
- **Expected:**
  - the refund is accepted; the payment becomes `part_refunded`
  - the second capture is accepted from `part_refunded`
  - ledger: captured 2500, refunded 400, balance 2100
  - the capturable amount was unaffected by the refund
- **Ref:** Stripe MC (refunds don't change `amount_capturable`).
- **Spec:** `spec/requests/v1/money_movement_spec.rb` · **Now:** ✅

**TC-E3-9. A full refund of the captured part, while capturing is open, isn't terminal**
- **Situation:** `capture 1000 final:false` succeeded. Then `refund 1000` succeeds.
- **Expected:**
  - state `part_refunded`, not `refunded`, and further captures are still allowed
  - after `capture 0 final:true`, the payment moves to `refunded`
- **Ref:** Stripe MC (fully refunded only after the final capture).
- **Spec:** `spec/jobs/refund_payment_job_spec.rb` · **Now:** ✅

**TC-E3-10. Multicapture refused on PSPs without it**
- **Situation:** A Kiripay payment, `capture {final: false}`.
- **Expected:** 400 `multicapture_unsupported`.
- **Ref:** Stripe MC (online cards only); DECISIONS #9.
- **Spec:** same · **Now:** ✅

**TC-E3-11. Capture count limit**
- **Situation:** 50 non-final captures have succeeded, and a 51st non-final one is sent.
- **Expected:** 422 `capture_limit_reached`. A final capture is still allowed.
- **Ref:** Stripe MC (50 non-final + 1 final).
- **Spec:** same · **Now:** ✅

**TC-E3-12. One `capture.succeeded` event per capture; `payment.captured` once**
- **Situation:** Two captures, of 1000 non-final and 1500 final.
- **Expected:**
  - two `capture.succeeded` events, each with `capture.id`, `amount_minor` and `capturable_minor` after it
  - exactly one `payment.captured`
- **Ref:** Adyen (a CAPTURE webhook per capture); Stripe (`charge.updated` per capture).
- **Spec:** `spec/jobs/capture_payment_job_spec.rb` · **Now:** ✅

**TC-E3-13. A failed capture emits `capture.failed` and leaves capturing open**
- **Situation:** A final capture is `Rejected` by the PSP.
- **Expected:** The capture is `failed`, a `capture.failed` event is written with `failure_code`, `captures_closed_at` stays nil, and the merchant may retry.
- **Spec:** same · **Now:** ✅

**TC-E3-14. The read-before-send rule holds for the second capture**
- **Situation:** The second capture's response is lost. The PSP total is already base + amount.
- **Expected:** The re-run books it without sending again.
- **Ref:** DECISIONS #20.
- **Spec:** `spec/jobs/capture_payment_job_spec.rb` · **Now:** ✅

**TC-E3-15. A partial-capture webhook from Nordpay books progress, not an illegal transition**
- **Situation:** The payment is `captured` (1000 of 2500, open). A Nordpay webhook arrives with `status: "authorized", captured_minor: 1000`.
- **Expected:** No transition error. The event is processed, and nothing more is booked.
- **Spec:** `spec/jobs/process_inbound_event_job_spec.rb` · **Now:** ✅

**TC-E3-16. Idle expiry closes an open remainder instead of voiding**
- **Situation:** A payment is `captured` 1000 of 2500, open, and idle for 6 days.
- **Expected:**
  - `captures_closed_at` set, with reason `authorization_expired`
  - state unchanged, with no PSP void
  - event `payment.captures_closed`
  - an `authorized` payment with nothing captured is still voided, as today
- **Ref:** Stripe (the remainder is released at the auth window; the payment ends succeeded); DECISIONS #14.
- **Spec:** `spec/jobs/expire_authorizations_job_spec.rb` · **Now:** ✅

**TC-E3-17. Cancel after a partial capture is refused, with a hint**
- **Situation:** A partly captured payment, and a cancel request.
- **Expected:** 400 `invalid_state` ("use a zero-amount final capture to release the remainder").
- **Ref:** Braintree (a partially settled parent can't be voided); Stripe (0-amount final capture).
- **Spec:** `spec/requests/v1/money_movement_spec.rb` · **Now:** ✅

**TC-E3-18. Existing captured payments are closed by the migration**
- **Situation:** Payments that were `captured`/`part_refunded`/`refunded` before the deploy.
- **Expected:** `captures_closed_at` is backfilled, so no old payment suddenly becomes capturable again.
- **Spec:** the migration spec in `spec/models/payment_spec.rb` · **Now:** ✅

**TC-E3-19. Simulation: multicapture is exercised and must succeed sometimes**
- **Situation:** The random driver issues non-final captures.
- **Expected:** The invariants still hold. In addition, the share of accepted second captures is > 0, and every refusal is an expected code.
- **Ref:** USE_CASES §1 bug 3 (the driver swallowed the error).
- **Spec:** `spec/simulation/payment_simulation_spec.rb` · **Now:** ✅

---

## 3. Missing tests on paths that already work

These need specs only; no code changes.

### Payments and idempotency

**TC-A2-1. Kiripay routing**
- **Situation:** POST VND, THB and IDR payments.
- **Expected:** `psp_name == "kiripay"`.
- **Spec:** `spec/requests/v1/payments_spec.rb`

**TC-A1-2. Nordpay routing for GBP and USD**
- **Situation:** POST GBP and USD payments.
- **Expected:** `psp_name == "nordpay"`.
- **Spec:** same

**TC-A4-1. Invalid amounts**
- **Situation:** `amount_minor` of 0, 25.5, "2500" and nil.
- **Expected:** 422 on `amount_minor`. No payment, and the idempotency key is not stored.
- **Spec:** same

**TC-A5-1. VND stored as-is**
- **Situation:** POST VND 50000.
- **Expected:** `amount_minor == 50000`, and the Kiripay body carries `"50000"`.
- **Ref:** ISO 4217 (exponent 0).
- **Spec:** same

**TC-A7-1. FX snapshot**
- **Situation:** Create a payment, then insert a newer EUR→USD rate.
- **Expected:** The payment's rate and its merchant-currency amount are unchanged.
- **Ref:** DOMAIN.md, `fx_rates`.
- **Spec:** same

**TC-A11-1. Same key, two merchants**
- **Situation:** Merchants M1 and M2 both send key K.
- **Expected:** Two payments.
- **Spec:** `spec/requests/v1/idempotency_spec.rb`

**TC-A12-1. Replay at 23h, fresh at 25h**
- **Situation:** Same key and body, sent again at +23h and at +25h.
- **Expected:** At +23h the response is replayed. At +25h a new payment is created.
- **Ref:** Stripe (keys kept ≥24h); Checkout.com (24h).
- **Spec:** same

**TC-E9-1. Capture / refund / cancel replay on v1**
- **Situation:** Same key and body sent twice to each endpoint.
- **Expected:** One capture row, one refund row, one cancel. The second response is replayed.
- **Spec:** same

### Authorization and recovery

**TC-B6-1. Kiripay 5xx → Unavailable, read timeout → TimedOut**
- **Spec:** `spec/adapters/kiripay_adapter_spec.rb`

**TC-B9-1. The DB refuses a second "current" transition**
- **Situation:** Raw insert of a second `most_recent: true` row.
- **Expected:** The unique index rejects it.
- **Spec:** `spec/models/payment_spec.rb`

**TC-C8-1. Circuit open → the authorize job leaves the payment pending, with no call**
- **Spec:** `spec/jobs/authorize_payment_job_spec.rb`

**TC-D7-1. A webhook resolves unknown → authorized**
- **Situation:** The payment is `unknown`. A webhook `authorized` arrives with a timestamp ≥ `first_sent_at`.
- **Expected:** `authorized`. `next_check_at` is cleared.
- **Ref:** DECISIONS #11.
- **Spec:** `spec/requests/v1/webhooks_spec.rb`

### Capture, refund, cancel

**TC-E5-1. Capture refused in non-capturable states**
- **Situation:** Capture on unknown, failed, canceled, requires_action and refunded payments.
- **Expected:** 400 `invalid_state` for each. No Capture row.
- **Spec:** `spec/requests/v1/money_movement_spec.rb`

**TC-E6-1. The DB allows one pending capture**
- **Situation:** Raw insert of a second pending capture.
- **Expected:** The unique index rejects it.
- **Spec:** `spec/models/capture_spec.rb` (new)

**TC-E8-1. The sweeper re-drives a stuck capture**
- **Situation:** A capture has been `pending` past `STUCK_AFTER`.
- **Expected:** `CapturePaymentJob` is enqueued with its id.
- **Spec:** `spec/jobs/stuck_payment_sweeper_job_spec.rb`

**TC-E10-1. Kiripay partial capture**
- **Expected:** 400 `partial_capture_unsupported`.
- **Spec:** `spec/requests/v1/money_movement_spec.rb`

**TC-F1-1. One full refund**
- **Situation:** A refund with no amount on a €25 captured payment.
- **Expected:** A €25 refund. The payment ends `refunded`.
- **Spec:** `spec/jobs/refund_payment_job_spec.rb`

**TC-F7-1. Refund refused unless captured**
- **Situation:** A refund on pending, canceled, failed and refunded payments.
- **Expected:** 400 `invalid_state` for each.
- **Spec:** `spec/requests/v1/money_movement_spec.rb`

**TC-F10-1. Refund events**
- **Situation:** A refund succeeds, and another fails.
- **Expected:** One `refund.succeeded` event and one `refund.failed` event (with `failure_code`). Each payload has `refund.id` and `amount_minor`.
- **Ref:** DOMAIN.md, "Letters to send".
- **Spec:** `spec/jobs/refund_payment_job_spec.rb`

**TC-E1-2 / TC-G1-2. `payment.captured` and `payment.canceled` events**
- **Situation:** A capture succeeds; an API cancel succeeds.
- **Expected:** One event of each type, written in the same transaction as the state change.
- **Spec:** `spec/jobs/capture_payment_job_spec.rb`, `spec/requests/v1/money_movement_spec.rb`

**TC-G4-1. The 6-day boundary**
- **Situation:** `updated_at` set to exactly 6 days ago, and to 6 days − 1 minute.
- **Expected:** The first is expired. The second is left alone.
- **Ref:** DECISIONS #14.
- **Spec:** `spec/jobs/expire_authorizations_job_spec.rb`

**TC-G7-1. The DOMAIN.md walkthrough, row by row**
- **Situation:** Anna pays €25. The payment is collected in full, then €10 is refunded, then the settlement line (€24.55 + €0.45 fee) arrives.
- **Expected:**
  - each step writes the rows in DOMAIN.md's table (with step 9 corrected to 2 outbound events)
  - the merchant balance is **€15.00**
  - every transfer nets to zero
  - no rows are updated or deleted in the append-only tables
- **Ref:** DOMAIN.md, "What gets written, each time something happens".
- **Spec:** `spec/requests/v1/domain_walkthrough_spec.rb` (new)

### Messages

**TC-D1-1. Nordpay webhook, end to end**
- **Situation:** A signed `charge.authorized` POST to `/v1/webhooks/nordpay`.
- **Expected:** 200. The event is stored, and the payment is `authorized`.
- **Spec:** `spec/requests/v1/webhooks_spec.rb`

**TC-D2-1. Nordpay bad signature**
- **Expected:** 401. The event is stored with `signature_valid: false` and is never applied.
- **Spec:** same

**TC-H3-1. Delivery timeout**
- **Situation:** The merchant endpoint times out.
- **Expected:** An attempt row with the error and `duration_ms`, and `next_attempt_at` = now + 2^(n−1) min.
- **Spec:** `spec/requests/v1/events_spec.rb`

**TC-H6-1. Production https-only, IPv4-mapped and 0.0.0.0**
- **Situation:** Webhook URLs `http://…`, `https://[::ffff:10.0.0.1]` and `https://0.0.0.0` in production.
- **Expected:** Each is refused.
- **Ref:** OWASP SSRF cheat sheet.
- **Spec:** `spec/lib/webhook_url_guard_spec.rb`

### Ledger and reconciliation

**TC-I1-1. An unbalanced transfer raises the alarm**
- **Situation:** Insert an unbalanced transfer with raw SQL, then run `ReconciliationJob`.
- **Expected:** The `ledger_imbalance_detected` metric and an ERROR log.
- **Spec:** `spec/jobs/reconciliation_job_spec.rb`

**TC-J7-1. Cache drift and PSP drift are detected**
- **Situation 1:** `captured_minor` cache ≠ the ledger. **Expected:** detected.
- **Situation 2:** The PSP total ≠ the ledger. **Expected:** detected.
- **Spec:** same

### Merchant platform and ops

These need specs only.

**TC-L1-1. The DB rejects a key whose prefix doesn't match its mode**
- **Situation:** Raw insert of a `sk_test_` prefix with `livemode: true`.
- **Expected:** The CHECK constraint fires.
- **Spec:** `spec/models/api_key_spec.rb`

**TC-M6-1. Step-up for sensitive merchant actions**
- **Situation:** Each sensitive merchant action without a fresh step-up: cancel, key roll/revoke, role change/remove, `roll_secret`, URL update, ownership transfer, recovery codes.
- **Expected:** 401 `step_up_required`.
- **Spec:** the matching dashboard request specs

**TC-M9-1. Routes are guarded by the right permission**
- **Situation:** A route→permission fixture.
- **Expected:** `authorization_inventory_spec` fails if a route is guarded by a different permission.
- **Spec:** `spec/routing/authorization_inventory_spec.rb`, `spec/fixtures/route_permissions.yml`

**TC-N8-1. Reject a proposal**
- **Expected:** State `rejected`, a `decision_note`, and an audit row.
- **Spec:** `spec/requests/ops/api/proposals_spec.rb`

**TC-N9-1. Apply fails**
- **Expected:** State `failed`. `error`, `decided_by` and `decided_at` are persisted.
- **Spec:** same

**TC-N10-1. Applying a proposal writes an outbound event**
- **Expected:** One outbound event.
- **Spec:** `spec/services/apply_proposal_spec.rb`

**TC-O1-1. A demo reset deletes nothing**
- **Expected:** The Payment and LedgerEntry counts are unchanged after a reset.
- **Spec:** `spec/requests/demo/api/ledger_and_resets_spec.rb`

---

## 4. Added by the independent code review

These were found by reviewing the merged fixes. Each one was written to fail first.

**TC-BUG2-3. A refusal of a refund that already landed succeeds, never fails** · **Now:** ✅
- **Situation:** A Kiripay refund POST landed, but its answer was lost (`Unavailable`, or a sweeper re-drive). The re-run's POST gets `409 already_refunded`.
- **Expected:** The job reads `fetch_refund` before failing. It finds `succeeded`, so the refund is `succeeded` and the reservation is posted to `refunds_paid`. The merchant balance is 0. There is no `refund.failed` event.
- **Ref:** DECISIONS #12, #16. Without this, the customer has the money and the merchant gets it back too: paid twice.
- **Spec:** `spec/jobs/refund_payment_job_spec.rb`

**TC-BUG2-4. A 2xx we could not read is not a refusal** · **Now:** ✅
- **Situation:** The adapter raises `Rejected(200)` because the response status was unparseable.
- **Expected:** The refund stays `pending` with its reservation held, and an ERROR log `refund.unreadable_response` is written.
- **Spec:** `spec/jobs/refund_payment_job_spec.rb`

**TC-BUG2-5. Kiripay never POSTs a refund for a charge already refunded** · **Now:** ✅
- **Situation:** A Kiripay charge's status is `refunded`, and `adapter.refund` is called again.
- **Expected:** It returns `Succeeded` from `fetch_refund`, with no POST.
- **Spec:** `spec/adapters/kiripay_adapter_spec.rb`

**TC-E3-20. A capture requested between the expiry query and the lock wins** · **Now:** ✅
- **Situation:** A payment is partly captured and idle for 6 days. A new capture is requested after the expiry job's query.
- **Expected:** `close_captures!(…, unless_capture_in_flight: true)` leaves capturing open, and no `payment.captures_closed` is sent.
- **Spec:** `spec/jobs/expire_authorizations_job_spec.rb`

**TC-E3-21. A capture queued past a close fails without calling the PSP** · **Now:** ✅
- **Situation:** A pending capture exists, and the payment has `captures_closed_at` set.
- **Expected:** The capture is `failed` with `captures_closed`. There is no fetch or capture call, and a `capture.failed` event is written.
- **Spec:** `spec/jobs/capture_payment_job_spec.rb`

**TC-J3-4. A settlement line we cannot store doesn't hide the rest of the report** · **Now:** ✅
- **Situation:** A `chargeback` line, which is a kind we don't model, is followed by a good capture line.
- **Expected:**
  - The run doesn't raise.
  - The odd line is logged `settlement.line_unreadable` and counted.
  - The next line is matched.
- **Spec:** `spec/jobs/settlement_reconciliation_job_spec.rb`

**TC-M14-4 / TC-M14-5. A failing audit write never hides the refusal** · **Now:** ✅
- **Situation:** `AuditEvent.record!` raises during a refused dashboard refund, and during a refused ops double-approval.
- **Expected:** The caller still gets the 422 or 409. The metric `audit_write_failed` is incremented and an ERROR log is written.
- **Spec:** `spec/requests/dashboard/api/payments_spec.rb`, `spec/requests/ops/api/proposals_spec.rb`

**Review fixes that are guarded by an existing TC:**
- The sweeper keeps going past an `IllegalTransition`: a lost race with a webhook. Spec: `stuck_payment_sweeper_job_spec.rb`.
- Ops "poll now" is refused for settled payments, so it can never re-send a charge. Spec: `ops/api/payments_spec.rb`.
- The late-success queue reads from its events through a partial index. TC-B3-3 is in `ops_queue_spec.rb`.

**Where a spec differs from the text above** (agreed during the fixes):
- **TC-N17-1** uses a double approval. No operator role can both propose and approve, so a self-approval never reaches the service.
- **TC-N7-2** forces the race with a stub, not with real threads.
- **TC-C4-1:** both racers carry the same PSP timestamp.
- **TC-D5-3:** an old event whose payment *does* exist is left to Sidekiq's retries; it isn't closed.
- **TC-B3-1:** a PSP that answers canceled or not-found after the timeout also fails the payment as `customer_action_expired`.
- **TC-A4-1:** asserts the 422 and no payment. The 422 answer **is** stored and replayed, like every 4xx. See the open decision in USE_CASES §1.
