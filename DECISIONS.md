# Decisions

Each entry: what we chose, what we rejected, and why. Ordered roughly by how much they shape the rest of the system.

## 1. `unknown` is a first-class payment state

**Decision:** A PSP timeout moves the payment to `unknown`. Only a status poll or a late webhook can move it out.

**Rejected:** Treating timeout as failure and retrying the authorize.

**Reason:** A timeout means the outcome is unobservable, not that it failed. The charge may have succeeded. Retrying a write we can't confirm is the one way to charge a customer twice. Polling is a read, which is safe to repeat; so we convert the ambiguous write into a definitive read before doing anything else.

## 2. `psp_reference` is generated and stored before the PSP call

**Decision:** We assign our own reference, write it to the `payments` row, then call the PSP with it.

**Rejected:** Storing the reference the PSP returns in its response.

**Reason:** If the response never arrives, a response-derived reference leaves us with nothing to look up. Pre-assigning it means a timed-out charge is always recoverable via `GET charge(ref)`. It also lets a retry carry the same reference, so a PSP with request-level idempotency (Nordpay) dedupes it for us.

## 3. Idempotency is enforced by a unique index, not a lookup

**Decision:** `INSERT` into `idempotency_keys` with `UNIQUE (merchant_id, key)`; rescue `RecordNotUnique` to replay or 409.

**Rejected:** `SELECT` to check for the key, then `INSERT` if absent.

**Reason:** Check-then-act has a gap. Two identical requests on two threads both pass the check and both proceed. The unique index is the only serialization point the database guarantees. A `request_fingerprint` alongside the key turns a reused key with a different body into a `422` instead of a silent wrong replay.

## 4. Webhook order is the PSP's timestamp, not arrival order

**Decision:** `payment_transitions` carries `sort_key` from the PSP's own timestamp and a `most_recent` flag with a partial unique index. Stale events are stored but do not change state.

**Rejected:** Applying each webhook as it arrives.

**Reason:** Nordpay can deliver `charge.captured` before `charge.authorized`. Applying on arrival walks the state backwards. Ordering by PSP time makes a 6-hour-late webhook still apply if it is the newest we have seen, and makes a merely out-of-order one a recorded no-op.

## 5. Balances are derived from an append-only double-entry ledger

**Decision:** No `balance` or `refunded_amount` columns. Every money movement is two rows that sum to zero per `transfer_id`. `GET /v1/balance` is a `SUM`.

**Rejected:** A cached balance column updated on each capture and refund.

**Reason:** A cached number has no history and cannot prove itself wrong; a duplicated write is invisible. With paired entries, a stray row breaks the zero-sum and `ledger_imbalance_detected` fires. Corrections are reversing entries, never edits — which is why `ledger_entries` has no `updated_at`.

## 6. Over-refund is prevented by a row lock plus a ledger sum

**Decision:** `RefundService` takes `SELECT ... FOR UPDATE` on the payment, sums captured and refunded from `ledger_entries`, then writes.

**Rejected:** Checking cached amount columns; or checking the ledger without a lock.

**Reason:** Two concurrent refunds must be serialized, and the number they check must be true. The lock gives order; the ledger sum gives truth. Either alone is insufficient — the lock with a cached column checks a possibly stale number; the sum without a lock has a gap between check and write.

## 7. Sweeper uses optimistic locking (`lock_version`) for stuck-payment recovery

**Decision:** The status-poller job loads stuck `pending`/`unknown` payments and applies the PSP's answer under `lock_version`; a `StaleObjectError` means another worker already resolved it.

**Rejected:** `FOR UPDATE` on every polled row.

**Reason:** The sweeper's critical section wraps an HTTP call to the PSP that can take up to 30 seconds. Holding `FOR UPDATE` across that call pins a database connection and blocks every other writer on that payment — including the inbound webhook handler — for the whole duration. Optimistic locking holds nothing: two sweepers may both poll, but only the first write lands, and the loser's `StaleObjectError` just means "already resolved, reload and move on." That is safe here because a status poll is a read with no side effects; losing the race costs one wasted HTTP call. It was not safe for refunds (#6) because there the critical section contains a money write, and a retry loop around money movement is exactly the kind of thing that double-charges.

## 8. `POST /v1/payments` returns 202 and does PSP work in Sidekiq

**Decision:** The request reserves the row and reference, enqueues the PSP call, and returns `202 pending` in milliseconds.

**Rejected:** Calling the PSP synchronously with a short timeout and returning `authorized` directly.

**Reason:** A synchronous call ties a Puma thread to the PSP's latency. With a 30-second timeout and a handful of threads, one slow PSP exhausts the web tier and every merchant's request queues behind it — an outage caused by a dependency we don't control. Returning `202` bounds the request at the cost of one database write. What the merchant gives up is the immediate `authorized`/`failed` answer; they get it instead through an outbound `payment.authorized` webhook or by polling `GET /v1/payments/:id`, both of which they need anyway for Kiripay, whose confirmation is webhook-only. So async is not an extra integration burden — it is the one model that works for both PSPs.

## 9. Amounts are integer minor units with a per-currency exponent table

**Decision:** `amount_minor` integer + ISO-4217 `currency` column. A frozen `CURRENCY_EXPONENT` hash (`VND => 0`, others `2`) drives display and PSP wire conversion.

**Rejected:** Decimal columns; or a hardcoded `/ 100`.

**Reason:** Floats and decimals accumulate rounding across millions of rows. `/ 100` is wrong for VND, which has no minor unit — `50000` is fifty thousand đồng, not five hundred. One lookup table for both directions means display and adapter can never disagree.

## 10. Adapters declare capabilities; the domain enforces rules

**Decision:** Each PSP adapter exposes flags such as `supports_partial_refund?`. `RefundService` checks them before locking or writing.

**Rejected:** `if psp_name == 'kiripay'` branches in the service; or letting the adapter reject at call time.

**Reason:** Branching on PSP name in domain code means every new PSP edits the service. Rejecting in the adapter is too late — the row is already locked, ledger possibly written, and the merchant already has a `202`. Capability flags keep the state machine a superset of all PSPs and let a rejection surface as an immediate `422 invalid_request`.

## 11. The state machine has exactly the edges in the spec diagram

**Decision:** `PaymentStateMachine::TRANSITIONS` encodes the README diagram verbatim. No `unknown → canceled`, no `requires_action → unknown`. A spec parses the Mermaid block and fails if code and diagram drift.

**Rejected:** Adding an operator cancel from `unknown`; adding a timeout path from `requires_action`.

**Reason:** Each state is a claim about the PSP's view of the world, and an edge exists only where we can honestly make the new claim. `canceled` claims a hold was released; from `unknown` we cannot know a hold exists, so the only honest exits are informational — `authorized` or `failed` via poll or webhook — and an operator giving up on a dead PSP uses `unknown → failed` with a reason, which the daily reconciliation then reviews. `requires_action` has nothing in flight to the PSP: it waits on the customer (3DS, wallet redirect), so a "timeout" there is abandonment (`failed`), not ambiguity (`unknown`). The one genuinely ambiguous Kiripay call — charge creation — happens in `pending`, which already reaches `unknown`. This matches how Stripe (`processing` cannot be canceled) and Adyen model it.
