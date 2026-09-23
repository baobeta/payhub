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

**Corollary — booking by comparison:** money for a capture-only PSP (Kiripay) is booked from the webhook through the same `BookCapture` as Nordpay's capture job: book the difference between what the PSP reports captured and what the ledger already holds. five copies of the same webhook, a webhook that races the sweeper, a webhook re-processed after a crash — all must book exactly once. Comparing two sources of truth (PSP total vs. ledger sum) is idempotent without remembering anything; a flag would have to be set atomically with the ledger write and checked everywhere. One booking path for both PSPs also means one place to be wrong.

## 6. Over-refund is prevented by a row lock plus a ledger sum

**Decision:** `RefundService` takes `SELECT ... FOR UPDATE` on the payment, sums captured and refunded from `ledger_entries`, then writes.

**Rejected:** Checking cached amount columns; or checking the ledger without a lock.

**Reason:** Two concurrent refunds must be serialized, and the number they check must be true. The lock gives order; the ledger sum gives truth. Either alone is insufficient — the lock with a cached column checks a possibly stale number; the sum without a lock has a gap between check and write.

**Refinement:** a refund's ledger legs are written only when the PSP confirms it, so between request and confirmation the money is *reserved*, not yet *refunded*. The guard therefore computes `refundable = captured − refunded (ledger) − pending (refunds table)`, all under the same lock. Without the reservation term, two €20 refunds on a €25 capture would both pass the check while the first is still in flight at the PSP. The real-threads test in `spec/services/create_refund_spec.rb` is the proof.

## 7. Sweeper uses optimistic locking (`lock_version`) for stuck-payment recovery

**Decision:** The status-poller job loads stuck `pending`/`unknown` payments and applies the PSP's answer under `lock_version`; a `StaleObjectError` means another worker already resolved it.

**Rejected:** `FOR UPDATE` on every polled row.

**Reason:** The sweeper's critical section wraps an HTTP call to the PSP that can take up to 30 seconds. Holding `FOR UPDATE` across that call pins a database connection and blocks every other writer on that payment — including the inbound webhook handler — for the whole duration. Optimistic locking holds nothing: two sweepers may both poll, but only the first write lands, and the loser's `StaleObjectError` just means "already resolved, reload and move on." That is safe here because a status poll is a read with no side effects; losing the race costs one wasted HTTP call. It was not safe for refunds (#6) because there the critical section contains a money write, and a retry loop around money movement is exactly the kind of thing that double-charges.

## 8. `POST /v1/payments` returns 202 and does PSP work in Sidekiq

**Decision:** The request reserves the row and reference, enqueues the PSP call, and returns `202 pending` in milliseconds.

**Rejected:** Calling the PSP synchronously with a short timeout and returning `authorized` directly.

**Reason:** A synchronous call ties a Puma thread to the PSP's latency. With a 30-second timeout and a handful of threads, one slow PSP exhausts the web tier and every merchant's request queues behind it — an outage caused by a dependency we don't control. Returning `202` bounds the request at the cost of one database write. What the merchant gives up is the immediate `authorized`/`failed` answer; they get it instead through an outbound `payment.authorized` webhook or by polling `GET /v1/payments/:id`, both of which they need anyway for Kiripay, whose confirmation is webhook-only. So async is not an extra integration burden — it is the one model that works for both PSPs.

**Corollary — transactional outbox:** the merchant's `payment.<state>` event is inserted by `Payment#transition!` in the *same* transaction as the state change, so the event exists if and only if the change committed; a sweeper delivers it later with signed POSTs, per-attempt rows, exponential backoff and a dead-letter state that `POST /v1/events/:id/redeliver` can replay. The rejected alternative — enqueue a Sidekiq job from the controller after commit — can lose the event when the process dies between commit and enqueue, or send it for a change that then rolled back. Concurrent sweepers partition the work with `FOR UPDATE SKIP LOCKED` rather than double-sending.

## 9. Adapters declare capabilities; the domain enforces rules

**Decision:** Each PSP adapter exposes flags such as `supports_partial_refund?`. `RefundService` checks them before locking or writing.

**Rejected:** `if psp_name == 'kiripay'` branches in the service; or letting the adapter reject at call time.

**Reason:** Branching on PSP name in domain code means every new PSP edits the service. Rejecting in the adapter is too late — the row is already locked, ledger possibly written, and the merchant already has a `202`. Capability flags keep the state machine a superset of all PSPs and let a rejection surface as an immediate `422 invalid_request`.

## 10. The state machine is the spec diagram plus exactly one edge

**Decision:** `PaymentStateMachine::TRANSITIONS` encodes the README diagram, plus two edges: `pending → failed` and `unknown → requires_action`. No `unknown → canceled`, no `requires_action → unknown`. A spec parses the Mermaid block and fails if code and diagram drift beyond the declared extras.

**Why the second extra edge:** a capture-only PSP's *create* call can time out (`unknown`); the lookup by our reference finds nothing; the re-send with the same reference succeeds and returns a redirect. The customer must now act — the honest state is `requires_action`, and the diagram has no path from `unknown` to it. The sweeper found this by crashing on it against real data, which is also why the sweeper now isolates one payment's illegal transition instead of aborting the batch.

**Rejected:** Routing a synchronous decline through `unknown` or `authorized` to stay inside the drawn edges; adding an operator cancel from `unknown`; adding a timeout path from `requires_action`.

**Why the extra edge:** Nordpay declines synchronously — HTTP 200, `status: declined` — while the payment is still `pending`. The diagram gives `failed` no edge from `pending`. Passing through `unknown` would claim ambiguity we don't have; through `authorized` would claim a hold that never existed. A decline is a verdict, and the honest edge is the direct one. The first job spec for the declined path found this gap; it is the kind of omission a diagram makes and an implementation cannot.

**Reason:** Each state is a claim about the PSP's view of the world, and an edge exists only where we can honestly make the new claim. `canceled` claims a hold was released; from `unknown` we cannot know a hold exists, so the only honest exits are informational — `authorized` or `failed` via poll or webhook — and an operator giving up on a dead PSP uses `unknown → failed` with a reason, which the daily reconciliation then reviews. `requires_action` has nothing in flight to the PSP: it waits on the customer (3DS, wallet redirect), so a "timeout" there is abandonment (`failed`), not ambiguity (`unknown`). The one genuinely ambiguous Kiripay call — charge creation — happens in `pending`, which already reaches `unknown`. This matches how Stripe (`processing` cannot be canceled) and Adyen model it.

## 11. `unknown` is dated from the moment we sent the request, not when we gave up

**Decision:** `AuthorizePaymentJob` captures `sent_at = Time.current` before calling the PSP, and on a timeout writes the `unknown` transition with `sort_key: sent_at`. The give-up time is kept in metadata.

**Rejected:** Dating `unknown` at the moment the client timed out.

**Reason:** Transitions are ordered by `sort_key`, and a PSP verdict older than the current row is treated as stale and not applied (#4). A PSP that records the charge and *then* hangs stamps that charge a few milliseconds after receiving it — well before our 3-second give-up. Dating `unknown` at give-up made the PSP's genuine timestamp look older than our own, so the poll result was recorded as stale and the payment sat in `unknown` forever; the sweeper would have hit the same wall. A PSP cannot record a charge before receiving it, so send time is the latest instant that is guaranteed to precede any real verdict. Found by running the timeout scenario end-to-end against the simulator; the job spec had used a PSP timestamp in the future, which no real PSP produces, and now builds it from the actual call time.

## 12. Kiripay is deduplicated by our own reference, because it has no idempotency key

**Decision:** Every Kiripay charge is created with our `psp_reference` as `merchant_reference`. On any ambiguity (timeout, retry, sweeper) we resolve by `GET /charges?merchant_reference=…`, never by re-POSTing. If Kiripay holds several charges for one reference, the earliest is treated as real and the rest are logged for reconciliation.

**Rejected:** Treating Kiripay's own charge id as the reference (it does not exist until the response arrives — a timeout leaves nothing to look up); adding a `kiripay_charge_id` column and branching on PSP in the jobs.

**Reason:** Nordpay honours `X-Request-Id`, so a retried authorize is deduplicated for us. Kiripay honours nothing: a second POST is a second charge. The only stable handle we control is the reference we chose *before* the first call (#2), so the adapter turns "find my charge" into a lookup by that reference and "several found" into a warning instead of a guess. The domain never learns any of this — `fetch(psp_reference)` has the same signature for both PSPs, which is the test of whether the adapter abstraction is real (#9).


## 13. The sweeper schedules each payment, instead of re-scanning the oldest

**Decision:** Every payment carries `next_check_at` and `check_attempts`. A sweep claims due payments with `FOR UPDATE SKIP LOCKED`, pushes each one's next check out by an exponential backoff with jitter (1, 2, 4, 8, 16, then every 30 minutes, ±20%) **before** polling, and releases the lock before any HTTP call. Half of each batch is the longest-overdue; the other half is the least-polled, most recently due. A state change resets the schedule. Operators poll one payment on demand with `StuckPaymentSweeperJob.poll_now`.

**Rejected:** `ORDER BY updated_at LIMIT 200` (what we had); pure oldest-first or pure newest-first; one global backoff for the whole sweeper.

**Reason:** The chaos run (`bin/rails chaos:run`) left one payment in `unknown` for good, and the cause was the sweeper, not the payment. A failed poll changes nothing on the row, so `updated_at` never moves and the same 200 oldest rows win every sweep. Once 200 payments can't be resolved (a PSP that lost them, a reference it rejects), the safety net quietly stops for everyone else — and the 15-minute alert keeps paging about the same old rows while new ones pile up behind them. The specs never showed this because each starts from an empty table; it takes a backlog, which is exactly what production looks like after an outage.

Rescheduling before the call means neither a failed poll nor a crash mid-batch can keep a row at the head of the queue. Backoff with jitter stops us hammering a PSP that is already struggling, and stops a batch that failed together from retrying together ([AWS: timeouts, retries and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)). Splitting the batch is the fairness guarantee: oldest-first alone lets an unresolvable backlog starve new work; newest-first alone lets steady new work starve the old. With both halves, a payment that has just gone `unknown` is polled within a minute and the oldest still make progress — the same reasoning as Facebook's adaptive LIFO for queues under overload ([Fail at Scale, ACM Queue](https://queue.acm.org/detail.cfm?id=2839461)). `SKIP LOCKED` lets two sweepers split the work instead of polling the same payment twice ([brandur: Postgres job queues](https://brandur.org/postgres-queues)), and the lock is held only for the claim, never across HTTP (#7).

**Cost:** a payment whose PSP stays silent is polled less often over time, so a genuinely lost webhook can take up to 30 minutes longer to resolve after a long outage. The runbook covers that: poll the affected payments directly once the PSP is back.
