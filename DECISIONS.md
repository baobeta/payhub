# Decisions

Each entry: what we chose in plain words, what we chose exactly, what we rejected and why, and the trade-off we accepted. For a non-technical overview of all of them, see [PayHub in plain words](docs/OVERVIEW.md). Ordered roughly by how much they shape the rest of the system.

## 1. `unknown` is a first-class payment state

**In plain words:** If the card company goes silent, we don't know whether the customer was charged. So we say "not sure yet" and ask, like calling the pizza place back to ask about order 123 instead of ordering again.

**Decision:** A PSP timeout moves the payment to `unknown`. Only a status poll or a late webhook can move it out.

**Rejected:** Treating timeout as failure and retrying the authorize.

**Reason:** A timeout means the outcome is unobservable, not that it failed. The charge may have succeeded. Retrying a write we can't confirm is the one way to charge a customer twice. Polling is a read, which is safe to repeat; so we convert the ambiguous write into a definitive read before doing anything else.

**Trade-off:** Shops must handle a third outcome besides yes and no. A payment can sit in `unknown` for a minute or longer (much longer if the PSP stays down), and a PSP that never answers needs a person to close it out (#23). We accept a slower, visible "we don't know" in exchange for never charging twice.

## 2. `psp_reference` is generated and stored before the PSP call

**In plain words:** We write our own label on the payment before we hand it over, so if no reply ever comes we still have something to ask about.

**Decision:** We assign our own reference, write it to the `payments` row, then call the PSP with it.

**Rejected:** Storing the reference the PSP returns in its response.

**Reason:** If the response never arrives, a response-derived reference leaves us with nothing to look up. Pre-assigning it means a timed-out charge is always recoverable via `GET charge(ref)`. It also lets a retry carry the same reference, so a PSP with request-level idempotency (Nordpay) dedupes it for us.

**Trade-off:** One extra database write before every PSP call. The reference format also has to be accepted by every PSP we add.

## 3. Idempotency is enforced by a unique index, not a lookup

**In plain words:** Like a coat check: each request carries a ticket number, and the database hands out one coat per ticket however many times it is waved.

**Decision:** `INSERT` into `idempotency_keys` with `UNIQUE (merchant_id, key)`; rescue `RecordNotUnique` to replay or 409.

**Rejected:** `SELECT` to check for the key, then `INSERT` if absent.

**Reason:** Check-then-act has a gap. Two identical requests on two threads both pass the check and both proceed. The unique index is the only serialization point the database guarantees. A `request_fingerprint` alongside the key turns a reused key with a different body into a `422` instead of a silent wrong replay. What is kept follows Stripe: an answer to a request that ran (2xx, or a 4xx such as `invalid_state`) is stored and replayed for 24 hours, but a `validation_failed` 422 or a 5xx releases the key. A request that fails validation never started, so there is nothing to reproduce, and keeping it would refuse the merchant's corrected retry as "key reused" ([Stripe: idempotent requests](https://docs.stripe.com/api/idempotent_requests); Checkout.com caches only 2xx).

**Trade-off:** Every `POST` costs an extra insert, and keys have to be stored for as long as replays are honoured. A duplicate that arrives while the first is still running gets a retriable `409` instead of waiting for the answer.

## 4. Webhook order is the PSP's timestamp, not arrival order

**In plain words:** Messages are sorted by the card company's postmark, not by when they landed in our mailbox, so a late message can't move a payment backwards.

**Decision:** `payment_transitions` carries `sort_key` from the PSP's own timestamp and a `most_recent` flag with a partial unique index. Stale events are stored but do not change state.

**Rejected:** Applying each webhook as it arrives.

**Reason:** Nordpay can deliver `charge.captured` before `charge.authorized`. Applying on arrival walks the state backwards. Ordering by PSP time makes a 6-hour-late webhook still apply if it is the newest we have seen, and makes a merely out-of-order one a recorded no-op.

**Trade-off:** We trust the PSP's clock. When its timestamps don't reflect the real order, or our own timestamps are chosen badly, a genuine verdict can look stale and be ignored; #11 is exactly that failure. Stale events are also stored forever, which costs space.

**Corollary, outbound:** we owe merchants what we ask of PSPs. Our webhooks are at-least-once and unordered, like Stripe's ([Stripe: webhooks](https://docs.stripe.com/webhooks)) and Checkout.com's ([Checkout.com: webhooks](https://www.checkout.com/docs/developer-resources/webhooks)): the outbox commits with the state change, a retry can follow a delivery whose 2xx we never saw, and a later event can overtake an earlier one that is still backing off. So every event carries `id` to dedupe on and `sequence`, a per-payment counter that only goes up, to drop a stale update — Adyen's `sequenceNumber` ([Adyen: handle webhook events](https://docs.adyen.com/development-resources/webhooks/handle-webhook-events)), and our own `sort_key` seen from the receiving end. `sequence` is `max + 1` under the payment's row lock, which every emitter already holds, with a unique index behind it; a counter column on `payments` would also work but writes the hottest row once more per event. Failed deliveries retry after 1m, 5m, 30m, 2h, 8h, 24h and 36h, and the event is dead after attempt 8, about 70.6 hours after the first: Stripe's "about 3 days", long enough to outlast a merchant's weekend outage, short of Adyen's 30 days because a dead event is redelivered by hand anyway. A redelivery gets 8 more attempts on the same schedule.

## 5. Balances are derived from an append-only double-entry ledger

**In plain words:** We keep an account book written in pen. Every movement is two lines that cancel out, a balance is the sum, and mistakes are fixed with new lines, never erased.

**Decision:** No `balance` or `refunded_amount` columns. Every money movement is two rows that sum to zero per `transfer_id`. `GET /v1/balance` is a `SUM`.

**Rejected:** A cached balance column updated on each capture and refund.

**Reason:** A cached number has no history and cannot prove itself wrong; a duplicated write is invisible. With paired entries, a stray row breaks the zero-sum and `ledger_imbalance_detected` fires. Corrections are reversing entries, never edits — which is why `ledger_entries` has no `updated_at`.

**Corollary — booking by comparison:** money for a capture-only PSP (Kiripay) is booked from the webhook through the same `BookCapture` as Nordpay's capture job: book the difference between what the PSP reports captured and what the ledger already holds. five copies of the same webhook, a webhook that races the sweeper, a webhook re-processed after a crash — all must book exactly once. Comparing two sources of truth (PSP total vs. ledger sum) is idempotent without remembering anything; a flag would have to be set atomically with the ledger write and checked everywhere. One booking path for both PSPs also means one place to be wrong.

**Trade-off:** Balances are computed, not read. Each `GET /v1/balance` sums rows, which gets slower as history grows and will eventually need periodic snapshots. Corrections take two more rows instead of one edit.

## 6. Over-refund is prevented by a row lock plus a ledger sum

**In plain words:** Refunds on one payment wait their turn, and each one counts what's really left before going ahead.

**Decision:** `RefundService` takes `SELECT ... FOR UPDATE` on the payment, sums captured and refunded from `ledger_entries`, then writes.

**Rejected:** Checking cached amount columns; or checking the ledger without a lock.

**Reason:** Two concurrent refunds must be serialized, and the number they check must be true. The lock gives order; the ledger sum gives truth. Either alone is insufficient — the lock with a cached column checks a possibly stale number; the sum without a lock has a gap between check and write.

**Refinement:** a refund's ledger legs are written only when the PSP confirms it, so between request and confirmation the money is *reserved*, not yet *refunded*. The guard therefore computes `refundable = captured − refunded (ledger) − pending (refunds table)`, all under the same lock. Without the reservation term, two €20 refunds on a €25 capture would both pass the check while the first is still in flight at the PSP. The real-threads test in `spec/services/create_refund_spec.rb` is the proof. *(The reservation now lives in the ledger rather than the refunds table — see #16.)*

**Trade-off:** Refunds on the same payment serialize on a row lock, so a burst of refunds on one hot payment queues. That's acceptable because concurrent refunds on one payment are rare and money safety comes first.

## 7. The sweeper holds no lock across the PSP call; each write takes a short row lock

**In plain words:** The night watch doesn't hold a payment hostage while it waits for a card company. If two helpers check the same payment, the second notices it's already done.

**Decision:** The sweeper polls stuck payments with no row lock held during the HTTP call. The lock is taken only for the write: `Payment#transition!` runs inside `with_lock` (`SELECT … FOR UPDATE`, which also reloads the row), checks the edge against the state it now sees, and writes. If another writer (a webhook, the job, a second sweeper) already moved the payment to the same state, the edge is illegal (`authorized → authorized`) and `ApplyPspResult` treats "already in that state" as done, logging `psp_result.already_in_state`. Any *other* illegal edge is a real bug and propagates. The short claim of a batch (`FOR UPDATE SKIP LOCKED`, #13) is also released before any HTTP call.

**Rejected:** `FOR UPDATE` held across the poll. Also optimistic locking with `lock_version` retries, which this entry used to describe: `payments` still has a `lock_version` column, but because every write path reloads the row under the lock first, a `StaleObjectError` cannot arise there, and the sweeper's rescue for it was dead code and has been removed.

**Reason:** The sweeper's poll is an HTTP call to the PSP that can take up to 30 seconds. Holding `FOR UPDATE` across that call pins a database connection and blocks every other writer on that payment — including the inbound webhook handler — for the whole duration. Locking only the write holds the row for milliseconds. Two writers can both poll, but the row lock serialises their writes, and the loser finds the payment already where the PSP says it is. That is safe because a status poll is a read with no side effects; losing the race costs one wasted HTTP call. A real-thread spec (TC-C4-1) races the sweeper against a webhook on the same payment and checks for one `authorized` transition, one `payment.authorized` event and no error. Refunds (#6) are different: there the critical section contains a money write, so the lock is held across the decision.

**Trade-off:** Two writers can occasionally poll the same payment, and the loser's HTTP call is wasted. That's cheap compared with pinning a connection and blocking webhooks for up to 30 seconds.

## 8. `POST /v1/payments` returns 202 and does PSP work in Sidekiq

**In plain words:** Like a restaurant handing you an order number: we answer "working on it" straight away and tell the shop the result when it's ready.

**Decision:** The request reserves the row and reference, enqueues the PSP call, and returns `202 pending` in milliseconds.

**Rejected:** Calling the PSP synchronously with a short timeout and returning `authorized` directly.

**Reason:** A synchronous call ties a Puma thread to the PSP's latency. With a 30-second timeout and a handful of threads, one slow PSP exhausts the web tier and every merchant's request queues behind it — an outage caused by a dependency we don't control. Returning `202` bounds the request at the cost of one database write. What the merchant gives up is the immediate `authorized`/`failed` answer; they get it instead through an outbound `payment.authorized` webhook or by polling `GET /v1/payments/:id`, both of which they need anyway for Kiripay, whose confirmation is webhook-only. So async is not an extra integration burden — it is the one model that works for both PSPs.

**Corollary — transactional outbox:** the merchant's `payment.<state>` event is inserted by `Payment#transition!` in the *same* transaction as the state change, so the event exists if and only if the change committed; a sweeper delivers it later with signed POSTs, per-attempt rows, exponential backoff and a dead-letter state that `POST /v1/events/:id/redeliver` can replay. The rejected alternative — enqueue a Sidekiq job from the controller after commit — can lose the event when the process dies between commit and enqueue, or send it for a change that then rolled back. Concurrent sweepers partition the work with `FOR UPDATE SKIP LOCKED` rather than double-sending.

**Trade-off:** Merchants don't get an immediate `authorized`/`failed` answer and must integrate webhooks or polling. We also run more moving parts (workers, outbox, sweepers) that must be monitored.

## 9. Adapters declare capabilities; the domain enforces rules

**In plain words:** Each card company plugs in through an adapter, like a travel plug, that says what it can and can't do. Our rules never mention a company by name.

**Decision:** Each PSP adapter exposes flags such as `supports_partial_refund?`. `RefundService` checks them before locking or writing. The flags today: `supports_partial_refund?`, `separate_authorize_and_capture?`, `supports_multicapture?` (several partial captures, #20; Nordpay yes, Kiripay no) and `supports_void?` (release a hold; Nordpay yes, Kiripay no). A cancel on a PSP that can't void is refused up front with `400 cancel_unsupported`, and the dashboard never offers it; `ExpireAuthorizationsJob` skips such holds and logs `authorization.expiry_unsupported` (#14). When a PSP still refuses a synchronous call, its `Rejected` becomes `409 psp_rejected` (`retriable: false`), never a 500.

**Rejected:** `if psp_name == 'kiripay'` branches in the service; or letting the adapter reject at call time.

**Reason:** Branching on PSP name in domain code means every new PSP edits the service. Rejecting in the adapter is too late — the row is already locked, ledger possibly written, and the merchant already has a `202`. Capability flags keep the state machine a superset of all PSPs and let a rejection surface as an immediate `422 invalid_request`.

**Trade-off:** The adapter interface has to be a superset of every PSP, and each new capability means a flag plus a domain check. The domain can only use features the abstraction knows about.

## 10. The state machine is the spec diagram plus exactly one edge

**In plain words:** Every stop a payment can be at is a claim about the real world, and a payment can only move where we can honestly make the new claim.

**Decision:** `PaymentStateMachine::TRANSITIONS` encodes the README diagram, plus two edges: `pending → failed` and `unknown → requires_action`. No `unknown → canceled`, no `requires_action → unknown`. A spec parses the Mermaid block and fails if code and diagram drift beyond the declared extras.

**Why the second extra edge:** a capture-only PSP's *create* call can time out (`unknown`); the lookup by our reference finds nothing; the re-send with the same reference succeeds and returns a redirect. The customer must now act — the honest state is `requires_action`, and the diagram has no path from `unknown` to it. The sweeper found this by crashing on it against real data, which is also why the sweeper now isolates one payment's illegal transition instead of aborting the batch.

**Rejected:** Routing a synchronous decline through `unknown` or `authorized` to stay inside the drawn edges; adding an operator cancel from `unknown`; adding a `requires_action → unknown` timeout edge.

**Why the extra edge:** Nordpay declines synchronously — HTTP 200, `status: declined` — while the payment is still `pending`. The diagram gives `failed` no edge from `pending`. Passing through `unknown` would claim ambiguity we don't have; through `authorized` would claim a hold that never existed. A decline is a verdict, and the honest edge is the direct one. The first job spec for the declined path found this gap; it is the kind of omission a diagram makes and an implementation cannot.

**Reason:** Each state is a claim about the PSP's view of the world, and an edge exists only where we can honestly make the new claim. `canceled` claims a hold was released; from `unknown` we cannot know a hold exists, so the only honest exits are informational — `authorized` or `failed` via poll or webhook — and an operator giving up on a dead PSP uses `unknown → failed` with a reason, which the daily reconciliation then reviews. `requires_action` has nothing in flight to the PSP: it waits on the customer (3DS, wallet redirect), so a "timeout" there is abandonment (`failed`), not ambiguity (`unknown`). The one genuinely ambiguous Kiripay call — charge creation — happens in `pending`, which already reaches `unknown`. This matches how Stripe (`processing` cannot be canceled) and Adyen model it.

**Abandonment, enforced:** the sweeper watches `requires_action` payments too. One whose `updated_at` (moved only by a state change, so it is the moment it entered `requires_action`) is older than `REQUIRES_ACTION_TIMEOUT` (30 minutes) is fetched by our reference, never re-sent. A verdict the PSP has reached applies as its webhook would have: `captured` is booked, `declined` fails. A PSP that is still waiting on the customer (or has no verdict) means the customer walked away: `failed` with `decline_code: "customer_action_expired"` and a `payment.failed` event. These payments are scheduled like stuck ones (#13) but never raise the stuck-payment alert, because a customer leaving is not an incident.

**Trade-off:** The strict map leaves some payments needing human review: there is no automatic `unknown → canceled`, so an operator must resolve a payment the PSP never answers for. Adding a state or edge means changing the diagram and the code together; the spec makes sure of that.

## 11. `unknown` is dated from the moment we sent the request, not when we gave up

**In plain words:** "Not sure yet" is dated from the moment we first sent the request, because the card company can't have charged anything before receiving it.

**Decision:** `AuthorizePaymentJob` captures `sent_at = Time.current` before calling the PSP, and on a timeout writes the `unknown` transition with `sort_key: sent_at`. The give-up time is kept in metadata.

**Rejected:** Dating `unknown` at the moment the client timed out.

**Reason:** Transitions are ordered by `sort_key`, and a PSP verdict older than the current row is treated as stale and not applied (#4). A PSP that records the charge and *then* hangs stamps that charge a few milliseconds after receiving it — well before our 3-second give-up. Dating `unknown` at give-up made the PSP's genuine timestamp look older than our own, so the poll result was recorded as stale and the payment sat in `unknown` forever; the sweeper would have hit the same wall. A PSP cannot record a charge before receiving it, so send time is the latest instant that is guaranteed to precede any real verdict. Found by running the timeout scenario end-to-end against the simulator; the job spec had used a PSP timestamp in the future, which no real PSP produces, and now builds it from the actual call time.

**Refinement — the *first* send, not this one:** "send time" assumed one send per reference. There can be several: the sweeper re-sends a still-`pending` payment after a 404 (#2), and the job that was queued behind it sends again. Nordpay answers the second send with the charge it created on the first, stamped then. The deterministic simulation (#19) found the consequence: a later job timed out, dated `unknown` at *its* send, and every verdict the PSP would ever report was older — the payment stayed `unknown` forever while the sweeper recorded 46 stale polls. `unknown` is now dated from `payments.first_sent_at`, written before any authorize leaves us (job or sweeper) with keep-earliest semantics in one statement, so racing senders agree on the earlier time. The argument is the same one, stated correctly: the PSP cannot record a charge before it *first* receives the reference.

**Trade-off:** One more column written before every send. `unknown` is dated slightly earlier than the moment we gave up, which is the conservative direction.

## 12. Kiripay is deduplicated by our own reference, because it has no idempotency key

**In plain words:** Kiripay doesn't protect against repeated requests, so we never repeat one. When in doubt we look the charge up by our own label.

**Decision:** Every Kiripay charge is created with our `psp_reference` as `merchant_reference`. On any ambiguity (timeout, retry, sweeper) we resolve by `GET /charges?merchant_reference=…`, never by re-POSTing. If Kiripay holds several charges for one reference, the earliest is treated as real and the rest are logged for reconciliation.

**How the code enforces it:** the adapter declares `idempotent_authorize?` (Nordpay true, Kiripay false; #9). For a PSP that answers false, a reference gets exactly one POST, ever. The sender must first win `Payment#claim_first_send!`, a single `UPDATE … WHERE first_sent_at IS NULL`, so a job and a sweeper racing on a never-sent payment cannot both send. Once `first_sent_at` is set, `AuthorizePaymentJob` (a 5xx retry, or a rerun after a crash between the POST and the state write) and the sweeper resolve by `fetch` instead. A lookup that finds nothing is answered by `ResolveUnknownPayment`: within `LOOKUP_GRACE` (30 minutes from `first_sent_at`) it is no verdict yet, since replica lag can hide a charge that exists, and the sweeper looks again; after it, the payment goes to `failed` with `decline_code: "psp_never_received"`, an ERROR log `resolve_unknown.psp_never_received` and the `psp_never_received` counter. Nordpay, which honours `X-Request-Id`, keeps the old behaviour: a 404 is answered by re-sending with the same reference.

**Rejected:** Treating Kiripay's own charge id as the reference (it does not exist until the response arrives — a timeout leaves nothing to look up); adding a `kiripay_charge_id` column and branching on PSP in the jobs.

**Reason:** Nordpay honours `X-Request-Id`, so a retried authorize is deduplicated for us. Kiripay honours nothing: a second POST is a second charge. The only stable handle we control is the reference we chose *before* the first call (#2), so the adapter turns "find my charge" into a lookup by that reference and "several found" into a warning instead of a guess. The domain never learns any of this — `fetch(psp_reference)` has the same signature for both PSPs, which is the test of whether the adapter abstraction is real (#9).

**Trade-off:** Every ambiguous Kiripay call costs an extra lookup. If Kiripay already holds duplicates, the customer may carry an extra charge until reconciliation catches it; we log it rather than guess. A Kiripay request that genuinely never landed (a 5xx before Kiripay recorded it, a connection refused after `first_sent_at` was written) is not re-sent: the payment fails as `psp_never_received` after 30 minutes and the shop must ask the customer to pay again. We accept a lost sale over a possible double charge. If the charge does appear after the grace, it arrives as a late webhook on a `failed` payment and is handled as a late success (an operator refunds it).

## 13. The sweeper schedules each payment, instead of re-scanning the oldest

**In plain words:** Like a nurse's rounds: each stuck payment has its own next-check time, and every round sees both the oldest and the newest, so nobody gets skipped forever.

**Decision:** Every payment carries `next_check_at` and `check_attempts`. A sweep claims due payments with `FOR UPDATE SKIP LOCKED`, pushes each one's next check out by an exponential backoff with jitter (1, 2, 4, 8, 16, then every 30 minutes, ±20%) **before** polling, and releases the lock before any HTTP call. Half of each batch is the longest-overdue; the other half is the least-polled, most recently due. A state change resets the schedule. Operators poll one payment on demand with `StuckPaymentSweeperJob.poll_now`.

**Rejected:** `ORDER BY updated_at LIMIT 200` (what we had); pure oldest-first or pure newest-first; one global backoff for the whole sweeper.

**Reason:** The chaos run (`bin/rails chaos:run`) left one payment in `unknown` for good, and the cause was the sweeper, not the payment. A failed poll changes nothing on the row, so `updated_at` never moves and the same 200 oldest rows win every sweep. Once 200 payments can't be resolved (a PSP that lost them, a reference it rejects), the safety net quietly stops for everyone else — and the 15-minute alert keeps paging about the same old rows while new ones pile up behind them. The specs never showed this because each starts from an empty table; it takes a backlog, which is exactly what production looks like after an outage.

Rescheduling before the call means neither a failed poll nor a crash mid-batch can keep a row at the head of the queue. Backoff with jitter stops us hammering a PSP that is already struggling, and stops a batch that failed together from retrying together ([AWS: timeouts, retries and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)). Splitting the batch is the fairness guarantee: oldest-first alone lets an unresolvable backlog starve new work; newest-first alone lets steady new work starve the old. With both halves, a payment that has just gone `unknown` is polled within a minute and the oldest still make progress — the same reasoning as Facebook's adaptive LIFO for queues under overload ([Fail at Scale, ACM Queue](https://queue.acm.org/detail.cfm?id=2839461)). `SKIP LOCKED` lets two sweepers split the work instead of polling the same payment twice ([brandur: Postgres job queues](https://brandur.org/postgres-queues)), and the lock is held only for the claim, never across HTTP (#7).

**Orphan webhooks get the same rule.** A webhook that arrives before our worker has written its payment row is stored unprocessed, and the sweeper re-drives it. That re-drive had the same bug: oldest-first with a limit, so a backlog of orphans that will never match (references we never made) starved a new one whose payment had just appeared. The sweeper now re-drives only orphans received in the last 24 hours, half the oldest and half the newest. An orphan older than 24 hours whose payment still does not exist is closed: marked processed with the error `orphan: no payment for reference`, an ERROR log `webhook.orphan_abandoned`, and the `orphan_webhooks_abandoned` counter, so a person can look at it. An old unprocessed event whose payment *does* exist is not an orphan but a processing failure, and is left to Sidekiq's retries.

**Trade-off:** A payment whose PSP stays silent is polled less often over time, so a genuinely lost webhook can take up to 30 minutes longer to resolve after a long outage. The runbook covers that: poll the affected payments directly once the PSP is back. A webhook whose payment row takes more than 24 hours to appear is closed rather than applied; the payment's own poll still reaches the PSP's answer.

## 14. An authorization nobody captures is voided after 6 idle days

**In plain words:** Like a hotel deposit: if a hold sits untouched for 6 days, we release it ourselves instead of leaving the customer's money frozen.

**Decision:** `ExpireAuthorizationsJob` runs hourly and voids any `authorized` payment with no activity for 6 days, through the same `CancelPayment` path as `POST /cancel`, with `source: "sweeper"` and `reason: "authorization_expired"`. The merchant gets the ordinary `payment.canceled` event. "Activity" is `updated_at`: a state change, or a capture request (`CapturePayment` touches the row under its lock). A void the PSP refuses is logged at ERROR and retried on the sweeper's backoff (#13).

**Rejected:** leaving holds to lapse at the card network; voiding immediately when a late poll turns `unknown` into `authorized`; a fixed deadline from creation.

**Reason:** A hold is the customer's money, frozen. When a charge sits in `unknown` for a while and only then resolves to `authorized`, the merchant may already have abandoned the order — and nothing in PayHub would ever release it. Letting the network drop it silently after ~7 days means the customer waits a week and the merchant never learns the order is dead. Stripe draws the same line: an uncaptured payment is canceled after 7 days ([Stripe: place a hold](https://docs.stripe.com/payments/place-a-hold-on-a-payment-method)); Adyen gives a cancel-by-reference for exactly this ambiguity ([Adyen: cancel](https://docs.adyen.com/online-payments/classic-integrations/modify-payments/cancel)). We void a day early so the release is ours and on the record.

Voiding the moment `unknown → authorized` lands would be wrong the other way: most late resolutions are minutes old and the merchant still wants the money; PayHub has no signal that an order was abandoned, so idle time is the honest proxy. Measuring from creation instead of activity would race a merchant who captures on day 6: their `202` would be followed by a void before the capture job ran, and the job would silently skip a canceled payment. Touching the row on capture closes that race without a new column.

**Partly captured payments:** since several partial captures exist (#20), a payment can be `captured` or `part_refunded` with capturing still open. After the same 6 idle days the job **closes** capturing on it (`captures_closed_at`, event `payment.captures_closed` with `reason: "authorization_expired"`). It does not void: money was already taken, and a void would be refused or would release the captured part. A payment whose captured money was all refunded becomes `refunded` at that moment. A PSP that cannot void (`supports_void?` false, #9) is skipped and logged once per hold period as `authorization.expiry_unsupported`.

**Not handled:** the uncaptured remainder is still not *released at the PSP*. Closing capturing is PayHub's own bookkeeping: no more captures, the merchant is told. The hold itself stays at the customer's bank until the network lets it lapse, and PayHub never claims otherwise. Recorded here rather than papered over.

**Trade-off:** A merchant that needs a longer hold (pre-orders, made-to-order goods) can't have one; they must capture within 6 days or ask the customer again. The leftover of a partial capture is closed, not released (see above).

## 15. Every webhook verifier takes a list of secrets

**In plain words:** Like changing the office locks while the old key keeps working for one more day, so nothing breaks during the switch.

**Decision:** Signing and verifying live in one module, `WebhookSignature`, and every verifier accepts a *list* of secrets. Inbound, each adapter reads `NORDPAY_WEBHOOK_SECRETS` / `KIRIPAY_WEBHOOK_SECRETS` (`new,old`), falling back to the single-secret variable. Outbound, a merchant keeps its previous secret for 24 hours after `rotate_webhook_secret!`, and each delivery carries one `v1=` per active secret. Kiripay and PayHub-to-merchant signatures sign `t.body` and are rejected outside a 5-minute window; Nordpay's are body-only, and stay that way.

**Rejected:** one secret per side (what we had); adding a timestamp to Nordpay's signature; per-event secret versioning.

**Reason:** With one secret, rotation is a flag day: the sender and receiver must switch in the same instant or webhooks fail verification — and failed PSP webhooks don't just bounce, they leave payments for the sweeper and page someone. Accepting several secrets for a while turns rotation into two independent, reversible steps. This is Stripe's scheme: during a roll it signs with both secrets and puts a `v1` per secret in one header ([Stripe: webhooks](https://docs.stripe.com/webhooks)). Rotation is what you do after a leak, so it has to be cheap enough to do the same day.

Every candidate pair is compared with `secure_compare` and no early exit, so timing shows neither which secret matched nor how close a forgery came.

We do not "fix" Nordpay by signing a timestamp: its signature scheme is the PSP's wire format, and a real PSP doesn't change it because we'd like it to. A replay there is stopped by the unique index on the PSP's event id (#4) — a replayed event is a duplicate — and a forged new event needs the secret. The timestamp window matters where we control the format: Kiripay's, and our own to merchants, where it stops a captured delivery being replayed later.

**Trade-off:** During the overlap a leaked old secret still verifies, for up to 24 hours outbound. Verifying against several secrets also costs one extra HMAC per secret.

## 16. Refund reservations are two-phase ledger transfers

**In plain words:** Money promised for a refund is set aside in the books immediately, like money spoken for when someone says "I'll put €20 on my card".

**Decision:** A refund request writes, in the same transaction as the refund row, a *reserve* transfer: debit `merchant_payable`, credit `refunds_reserved`. The PSP's answer settles it with a second transfer — *post* (debit `refunds_reserved`, credit `refunds_paid`) or *void* (debit `refunds_reserved`, credit `merchant_payable`). The guard's reservation term is now `Ledger.reserved_minor`, a ledger sum like the other two. A unique index on `(refund_id, account_id, direction)` makes a second post, or a post after a void, a database error. `GET /v1/balance` shows `pending` beside `available`. The migration backfills a reservation for every refund in flight at deploy.

**Rejected:** keeping the reservation as `SUM(refunds.amount_minor) WHERE state = 'pending'` (what we had); a `status` column on ledger entries that flips pending → posted; reserving in Redis.

**Reason:** #5 says balances come from the ledger and nothing else, but the refund guard had one term that didn't: pending refunds were counted from the refunds table. That worked, but it meant the money a merchant was actually owed at any moment existed nowhere as a balance — `GET /v1/balance` over-reported by every refund in flight, and reconciliation had no row to check a reservation against. Two-phase transfers are how purpose-built ledgers do it: TigerBeetle reserves with a pending transfer and settles with a second transfer that posts or voids it ([TigerBeetle: two-phase transfers](https://docs.tigerbeetle.com/coding/two-phase-transfers/)); Modern Treasury separates pending, posted and available balances ([Modern Treasury: balances](https://docs.moderntreasury.com/ledgers/docs/transaction-status-and-balances)).

We settle with a new transfer rather than flipping a status column, because the ledger is append-only by trigger (#5) and must stay that way: every step is a row, so the history of a refund is readable from the books alone. The unique index is the ledger-level answer to "what if the job runs twice?" — the job already checks the refund's state under a lock, and now the database refuses the second settlement even if that check were wrong. Reconciliation adds one question it couldn't ask before: does every pending refund hold exactly its amount, and every settled one nothing?

**Trade-off:** `available` now drops when a refund is *requested*, not when it succeeds, and comes back if the PSP refuses it. That is the honest number, because the money is spoken for, and `pending` shows where it went.

## 17. A circuit breaker per PSP — and the one rule any future failover must obey

**In plain words:** Like a fuse box: when a card company keeps failing, the fuse trips, we stop calling it for 30 seconds, then try once.

**Decision:** Every adapter call goes through `PspCircuit`, one circuit per PSP with its state in Redis. It opens when at least 10 calls in a 30-second window have failed 50% or more — a failure being `TimedOut` or `Unavailable`, never a decline or 4xx — refuses every call for 30 seconds, then lets exactly one probe through: success closes it, failure re-opens it. A refused call raises `PspCircuit::Open`, which *is* an `Unavailable`, so each caller's existing path applies: the authorize job retries, the sweeper skips and backs off (#13), `POST /cancel` returns a retriable 503.

**Rule for failover, recorded now because there is no failover yet:** a payment may be sent to a second PSP only when the first provably never received it — the circuit was open, or the connection was refused before any byte was sent. **Never after a timeout or a 5xx on a charge.** Those are ambiguous; the only way out of ambiguity is a read (#1).

**Rejected:** N consecutive failures (the simulator's 20% flaky 500s would trip it all day); a per-process breaker; counting declines as failures; failing over on timeout "because the customer is waiting".

**Reason:** When a PSP is down, every call we make to it holds a worker thread for the full 3-second timeout, turns a `pending` payment into an `unknown` one, and adds load to a service that is trying to recover. A breaker converts a slow, ambiguous failure into a fast, unambiguous one: an open circuit means the request never left, which is strictly better than a timeout for everything downstream. The half-open probe is what lets it close without a human. Keeping state in Redis matters because the web tier and every Sidekiq process hit the same PSP; a per-process breaker would need each of them to rediscover the outage separately ([Martin Fowler: CircuitBreaker](https://martinfowler.com/bliki/CircuitBreaker.html)). A rate over a window rather than a consecutive count is what lets a flaky-but-alive PSP stay closed.

The failover rule comes from the orchestrators that do route across PSPs. Spreedly's Recover fails over on an open breaker or a pre-send error, and explicitly **does not retry after a timeout**, "because we can't be certain the transaction wasn't attempted" ([Spreedly: Recover](https://developer.spreedly.com/docs/recover)); Primer falls back only on soft declines ([Primer: fallbacks](https://primer.io/blog/why-merchants-should-build-a-fallback-strategy)). Smart routing is where orchestrators most often invent double charges, so the rule is written down before the feature exists, and the breaker's `Open` is the signal it will key on.

**Trade-off:** While a circuit is open, payments to that PSP wait (in `pending`) instead of trying. With a 30-second cooldown that is the right trade; an outage longer than that shows up on the dashboards, not as a wall of `unknown`. A slightly flaky PSP that crosses the 50% threshold briefly will also pause traffic it could have served.

## 18. Reconcile against what the PSP paid, not only what its API says

**In plain words:** Like checking your bank statement against your receipts: every day we compare what the card company actually paid with what our books say.

**Decision:** `SettlementReconciliationJob` runs daily after the API reconciliation. For every PSP that publishes a settlement report (Nordpay: a CSV per UTC day, one line per capture net of fee and per refund), it ingests each line exactly once, matches it to our books, and books the matched ones: a capture clears `psp_receivable` into `psp_payouts` and `psp_fees`; a refund clears `refunds_paid` against `psp_payouts`. Lines that don't add up (net ≠ gross − fee), match nothing, are in another currency, settle more than the ledger captured, pay a refund our books still call pending or for another amount, or settle a refund another line already settled are stored with the problem, logged at ERROR, counted, and never booked; a booking the ledger refuses is flagged the same way and the run carries on. Several capture lines for one payment are normal (one per capture). Captures not settled within 3 days are flagged. Kiripay publishes no report we can fetch: its run logs `settlement.no_report` and still flags its captures older than 3 days, the check Stripe falls back to without a report ([Stripe: payout reconciliation](https://docs.stripe.com/payouts/reconciliation)).

**Rejected:** relying on the daily API check alone (#6's ReconciliationJob); booking discrepancies anyway "so the books balance"; matching payouts against the bank statement (the third leg of a three-way reconciliation) — out of scope, recorded here.

**Reason:** The API reconciliation asks the PSP what it *thinks* happened to each charge. A settlement report is what it actually *paid*, with fees, and it is the only place some failures show: a capture the PSP never pays out, a fee we didn't expect, a payout for a charge we never booked. That last one is the one rule seen from the other side — if the PSP settles more for a payment than our ledger captured, a customer was charged more than we know about. Adyen's Settlement Details Report is per transaction for exactly this ([Adyen: settlement details report](https://docs.adyen.com/reporting/settlement-reconciliation/transaction-level/settlement-details-report)); Stripe reconciles payouts from balance transactions ([Stripe: payout reconciliation](https://docs.stripe.com/reports/payout-reconciliation)) and measures its own ledger by whether every movement *clears* ([Stripe: Ledger](https://stripe.dev/blog/ledger-stripe-system-for-tracking-and-validating-money-movement)).

Clearing is the point of the accounts: `psp_receivable` rises at capture and falls at settlement, so a receivable that never returns to zero *is* the unsettled-capture report — a ledger sum, not a separate table. Unmatched lines are never booked because the ledger records what we can explain; a discrepancy that is booked to make the numbers agree is a discrepancy nobody will look at again. Lines are unique on the PSP's line id, so re-fetching a report is harmless.

**Not handled:** the bank leg (payout ↔ deposit), chargebacks, and fee disputes. The accounts are shaped for them — `psp_payouts` is exactly what a bank statement would be matched against — but the data isn't there.

**Trade-off:** Discrepancies surface a day late, not in real time. Kiripay is checked only for captures that never settle, never line by line, and every unmatched line needs a person, which costs operations time.

## 19. A seeded, deterministic simulation holds the whole system to the PSP's truth

**In plain words:** A flight simulator for payments: the real code runs against a pretend card company where one number decides every fault, so any failure can be replayed exactly.

**Decision:** `spec/simulation` runs the real services and jobs against `SimPsp`, an in-process PSP that honours the adapter contract and keeps the truth of what it charged and refunded. One seed drives everything: the PSP's faults (refuse before recording, record then lose the response, read timeouts, declines, webhooks lost or doubled), the order jobs run in, which jobs run twice (a crash after commit), when webhooks arrive, what merchants do (create, capture, refund, cancel), when sweepers and expiry run, and a virtual clock that sometimes jumps days. After every step: the ledger balances; `refunded + reserved ≤ captured ≤ authorized`; the ledger never books money the PSP did not move; the PSP holds no charge we didn't create; and the customer is never charged more than the merchant asked to capture. Then faults stop, everything drains, and the books must equal the PSP's truth exactly, with nothing left `pending` or `unknown`. A failure prints the seed; `SIM_SEED=<seed>` replays it step for step. `bin/check` runs 4 seeds × 150 steps; `SIM_RUNS`/`SIM_STEPS` run more.

**Rejected:** more example-based specs; randomised tests without a replayable seed; black-box fault injection alone (the chaos run, which stays, but is slow, not replayable, and can only see what the HTTP API exposes).

**Reason:** Every bug worth having in this system is an interleaving — a retry that overlaps a webhook that overlaps a sweep — and example specs only test the interleavings someone thought of. TigerBeetle's VOPR and FoundationDB's simulator made the case: run the real code under a simulated world driven by one seed, check invariants continuously, and a failure is a seed you can replay rather than a flake you can't ([TigerBeetle: VOPR](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md), [FoundationDB: testing](https://apple.github.io/foundationdb/testing.html)). This one is scaled to what a Rails app can control — the PSP, the job queue, webhook delivery and time — not threads or disks.

It earned its place on its first runs. Twenty seeds found two defects every existing spec had passed: a payment stranded in `unknown` forever by a timestamp rule that assumed one send per reference (#11's refinement), and a partial capture sent twice after a lost response — the customer charged double what the merchant asked, with the ledger faithfully matching the PSP, so no ledger check could see it (#20). The second is why the "charged no more than asked" invariant exists: consistency between our books and the PSP is not the same as correctness for the customer.

**Trade-off:** Every `bin/check` run takes about 15 seconds longer, and `SimPsp` must be kept faithful to how real PSPs behave, or it gives false confidence. The simulation runs one step at a time, so races within a step are left to the real-thread specs.

## 20. A capture is a row, and the job reads the PSP before it writes

**In plain words:** Before reordering a parcel that seems lost, check the tracking page. Before collecting money, we ask how much has already been collected.

**Decision:** Each merchant capture request is a `captures` row (`amount_minor`, and `base_captured_minor` — the ledger's total when it was accepted). At most one capture per payment may be `pending`, enforced by a partial unique index; a second request gets a retriable `409 capture_in_progress`. `CapturePaymentJob` takes a capture id and **reads the PSP's running total before sending**: if it already reaches `base + amount`, an earlier run's capture landed and is booked without sending again. It sends only after a read that says it has not landed; a failed read raises and retries, never sends blind. The sweeper re-drives captures left pending; authorization expiry skips a payment with a capture in flight.

**Rejected:** relying on "book only the difference" (what we had); an idempotency key on the capture call (Nordpay's capture honours none — and the fix must not depend on the PSP); allowing concurrent captures per payment.

**Reason:** Booking was idempotent — the ledger books only the difference between the PSP's total and its own — and the job was specced as "perform twice, ledger unchanged". But the PSP's capture call is not idempotent: sent twice, it captures twice. A Sidekiq redelivery, or a retry after a capture whose response and follow-up read were both lost, sent the partial capture again; the PSP accepted it (still within the authorization) and the ledger, faithfully, booked it. Books and PSP agreed; the customer paid double. The deterministic simulation (#19) found it in 5 of 20 seeds; the old "perform twice" spec had scripted the PSP to return the same total twice, which a real PSP doesn't — it encoded the bug instead of catching it.

Serializing captures per payment is what makes the read sufficient: with one capture in flight and a running total that only grows, "has it landed?" is `total ≥ base + amount`, with no ambiguity about whose capture moved the total. The 409 costs a merchant who fires two partial captures at once one retry; it is the same trade #6 makes for refunds. Refunds didn't have this bug because Nordpay's refund call *is* idempotent on our reference (#6) — which is the general rule: an operation is safe to retry only if the PSP deduplicates it or we can prove from a read that it hasn't happened.

**Several partial captures.** A capture takes `final` (default `true`), following Stripe's `final_capture` ([Stripe: multicapture](https://docs.stripe.com/payments/multicapture)) and Checkout.com's `capture_type` (`Final` by default, `NonFinal` keeps the rest open: [Checkout.com: capture](https://www.checkout.com/docs/payments/manage-payments/capture-a-payment)). The rules:
- A capture is allowed from `authorized`, `captured` or `part_refunded` while `payments.captures_closed_at` is nil and money remains. The first booking still moves the payment to `captured`, because money moved (#10).
- A final capture that succeeds closes capturing. So does `amount_minor: 0, final: true`, with no PSP call and no Capture row (`200`); on a payment with nothing captured that is refused, because releasing the whole hold is what cancel is for. A closed payment answers `400 capture_closed`.
- `final: false` needs the adapter's `supports_multicapture?` (#9); otherwise `400 multicapture_unsupported`. At most 50 non-final captures per payment (`422 capture_limit_reached`), as Stripe; a final one is still allowed after them.
- Refunds may come between captures, up to captured − refunded − reserved, and don't change what is still capturable. A payment becomes `refunded` only when capturing is closed **and** refunded ≥ captured; closing a fully refunded `part_refunded` payment moves it to `refunded`.
- Each capture gets its own event, `capture.succeeded` or `capture.failed` (the capture's id, amount, and `capturable_minor` after it), as Adyen sends a CAPTURE webhook per capture ([Adyen: capture](https://docs.adyen.com/online-payments/capture)). `payment.captured` stays one per payment. Closing with money left uncaptured sends `payment.captures_closed` with the reason and `released_minor`.
- Webhooks book the PSP's own running total (`captured_minor`) when the event carries one. Nordpay reports a partial capture as a charge still `authorized` with `captured_minor > 0`; on a payment already past `authorized` that books progress and never moves state back. A PSP that reports no amount (Kiripay) only ever captures in full.
- Existing captured, part-refunded and refunded payments were closed by the migration, so no old payment became capturable again.
- `GET /v1/payments/:id` shows `amount_capturable_minor`; the dashboard's `can.capturable_minor` is the same figure from the ledger.

The uncaptured remainder is not released at the PSP (#14). Adyen does the same: with several partial captures the rest is not auto-cancelled, it is cancelled by the merchant or expires.

**Deploy note:** jobs already queued with the old `(payment_id, amount)` arguments are adopted as captures on first run. A legacy job *redelivered after it already booked* can't be told from a fresh one; drain the `payments` queue before deploying this change.

**Trade-off:** Every capture costs an extra PSP read before the send. A merchant that fires two partial captures at once gets a retriable `409` and must retry the second.

## 21. A UI, kept beside the API rather than in it

**In plain words:** The dashboards live next to the API in the same app, but the API itself stays exactly as it was.

**Decision:** Three Vue bundles (`merchant`, `ops`, `demo`) served by Vite Ruby from the same Rails app, each from its own shell page (`/dashboard`, `/ops`, `/demo`) behind `Web::BaseController < ActionController::Base`. `/v1` is unchanged: `ActionController::API`, Bearer keys, no cookies.

**Rejected:** a separate SPA calling `/v1` over CORS.

**Reason:** Same-origin cookie sessions keep secret API keys out of the browser, and the assignment's "no UI" scope is preserved for the API itself — nothing the UI adds is reachable through `/v1`. Three bundles rather than one means a merchant's browser never downloads the operator console's code.

**Trade-off:** UI and API share one deployable and one failure domain: a bad UI deploy ships with the API, and the Rails build now depends on a Node/Vite toolchain.

## 22. Test mode is a twin merchant

**In plain words:** Every live shop gets a test twin, like a flight simulator with the same cockpit and no passengers.

**Decision:** Each live merchant has at most one test-mode twin (`merchants.livemode = false`, `live_merchant_id` → the live row, one twin enforced by a unique index and the shape by a CHECK). Keys live in `api_keys`; an `sk_test_` key authenticates as the twin.

**Rejected:** a `livemode` column on payments, refunds, captures, ledger accounts and events.

**Reason:** Every query is already scoped by merchant, so separation comes from scoping that exists and is already tested, rather than a new filter every query must remember. The ledger, the chaos run and the simulation are untouched.

**Trade-off:** Each live merchant can have a second merchant row, and anything that wants live and test numbers together has to join the twin.

**Held by the database (L4, M10):** twins don't nest, as [Stripe sandboxes](https://docs.stripe.com/sandboxes) don't: a trigger (`trg_merchants_twin_parent_is_live`) refuses a `live_merchant_id` that points at a non-live merchant. And a team has exactly [one owner](https://support.stripe.com/questions/change-account-owner): the partial unique index stops a second, and a `DEFERRABLE INITIALLY DEFERRED` constraint trigger (`trg_merchant_users_keep_one_owner`) refuses, at commit, a live merchant with active members and no active owner. Checking at commit lets `TransferOwnership` demote then promote in one transaction, and lets a brand-new merchant exist before its first owner is invited. The migration that installs both triggers first checks the existing rows and aborts the deploy with the offending ids (TC-M10-3), because the owner trigger only checks rows that change: data that already breaks the rule would otherwise surface later as a failure of some unrelated write. RUNBOOK "Deploy stopped: merchant without an owner" has the queries and the fix.

## 23. Operators change money only with two people

**In plain words:** Like a bank vault with two keys held by two people: one staff member proposes a money change, and a different one approves it.

**Decision:** Manual exits from `unknown` and ledger corrections are `operator_proposals`: a maker records the intended change (a `payment_transition` with `to_state`, or a `ledger_correction` with balanced legs), a reason code, free text and a case reference; a different operator approves it. No operator role holds both `ops.proposals.create` and `ops.proposals.decide`; the operator admin holds neither.

The "proposer ≠ approver" rule is enforced in three places: `OperatorProposal#approvable_by?` computes the `can.approve`/`can.reject` flags the UI shows, the same check runs again under `SELECT … FOR UPDATE` in `DecideProposal`, and a database CHECK (`chk_operator_proposals_not_self`) is the backstop. `DecideProposal` writes the decision first, then applies it inside a nested transaction (`requires_new: true`, a savepoint): a failed apply rolls back only the apply, so the decision and a `state = "failed"` row with the error still commit and the approver can see what happened. Only `unknown → authorized` and `unknown → failed` exist from `unknown`; `pending` is left to the worker and the sweeper.

**Rejected:** a single operator transition with a reason (the previous RUNBOOK §5); enforcing proposer ≠ approver by convention alone.

**Reason:** Segregation of duties is the baseline for manual money movement (`reports/RBAC implementation patterns.md`), and "proposer ≠ approver" is worth a CHECK constraint, not just a code path. Failing the whole decision on a failed apply would lose the approver's intent and hide the error; the savepoint keeps the audit trail honest.

**Trade-off:** Manual fixes are slower and need two operators available, which is hard at 3am or in a small team. We accept the delay because a single person moving money is the larger risk.

**Frozen and expiring (N6):** as in [Stripe Approvals](https://docs.stripe.com/account/approvals), a request is approved exactly as captured and expires after 14 days. The immutability trigger covers the reason (`reason_code`, `reason_text`, `case_reference`) as well as the payload. `ExpireProposalsJob` runs daily, moves proposals still `pending` after 14 days to `expired` under the same row lock `DecideProposal` takes, and audits each as `proposal.expired` with the system as actor. Approving, rejecting or withdrawing an expired proposal answers `409`; the maker resubmits if the change is still needed.

## 24. Permissions are a catalogue in code, checked per action, verified in CI

**In plain words:** A fixed list of named keys for named doors, kept in code. Every door says which key it needs, and automatic checks catch any door that forgot.

**Decision:** `resource.verb` permissions and fixed roles in `app/lib/permissions.rb`, validated at boot. Every UI action declares `requires_permission` or `allow_unauthorized`; a denial is a 403 and an append-only `audit_events` row. CI enforces it three ways: a route inventory (every Web route is declared), an independent hand-written matrix (`spec/fixtures/permission_matrix.yml`), and a grep that forbids checking role names. The docs table and the TypeScript permission type are generated from the catalogue and fail `bin/check` when stale.

**Rejected:** Pundit/CanCanCan, a policy engine (OPA, Cedar), permissions in the database.

**Reason:** Nine fixed roles do not need them. Each deferred option has a written trigger in design §3 (custom roles → database; per-record rules → policy objects). The matrix is hand-written on purpose: expectations derived from the code under test cannot disagree with it.

**Trade-off:** No custom roles: changing what a role can do is a code change and a release. Each future need has a written trigger (design §3) for when to move to a database or policy objects.

## 25. Merchant sign-in: database sessions, mandatory TOTP, step-up for sensitive actions

**In plain words:** Badge into the building with a password and an app code, then badge again at the server room before touching money or secrets.

**Decision:** A browser session is a row in `sessions` (polymorphic, shared with operators in phase 2) behind a signed, path-scoped, `HttpOnly`, `SameSite=Strict` cookie that holds only the row id. Sign-in is password, then a TOTP code (or a single-use recovery code). The password step alone creates no session: it sets a 5-minute encrypted cookie that only the code step accepts. Enrolling an authenticator is part of accepting an invitation, and a user cannot sign in until it is done. Every permission marked sensitive in the catalogue also needs a code entered in the last 10 minutes (step-up), answered as `401 step_up_required` so the UI can ask and retry the same request with the same idempotency key. Ten failures, of the password or the code, lock the account for 30 minutes. Sessions end after 15 idle minutes and at most 12 hours. TOTP secrets are encrypted at rest, and a code is accepted once (the time step is remembered).

**Rejected:** Devise (a large surface for fixed roles, invitations only and no self-sign-up); cookie-only sessions (cannot be revoked when a role changes or a person is removed); SMS codes (SIM swapping); passkeys for now (enterprise tier in the use cases).

**Reason:** PCI DSS 8.2.8 (idle timeout), 8.3.4 (lockout) and 8.4 (MFA for access to the cardholder-data environment's admin functions), and use cases A-01 to A-07. Revocation is the deciding property: removing a teammate or changing a role must take effect on their very next request, which needs a server-side session row and the role read from the database every time.

**Trade-off:** Every user carries an authenticator and sees step-up prompts. Each request reads the session from the database. And because lockout exists, someone who knows a user's email can deliberately lock that account for 30 minutes.

**Lost authenticator (M12):** as in [Stripe's 2FA recovery](https://support.stripe.com/questions/what-do-i-do-if-i-ve-lost-access-to-my-two-step-verification-codes), an admin with `team.manage` and step-up resets a member's authenticator, and the member gets an email with a recovery link. The reset clears the authenticator and recovery codes, ends every session, and stores the SHA-256 digest of a single-use token that expires after 72 hours (`merchant_users.otp_reset_digest` / `otp_reset_expires_at`, like an invitation's). Enrolling a new authenticator needs both the link's token and the password: `POST /session` with `reset_token`, then the usual enrol cookie and `otp/setup` + `otp/confirm`. The token is spent by a conditional UPDATE at the password step, so a replayed link fails. A correct password with no valid token answers the same `401 invalid_credentials` as a wrong one, so a sign-in attempt cannot tell that an account was reset. An expired link is refused; the admin resets again. **Rejected:** re-enrolling on the password alone (the previous behaviour): anyone holding a leaked password could then bind their own authenticator to an account an admin had just reset. **Trade-off:** a member who lets the link lapse, or closes the tab between the password and the code, needs another reset.

## 26. Operator writes are made safe by state, not idempotency keys

**In plain words:** Staff actions are made safe by checking the situation ("is this still waiting for approval?") rather than by ticket numbers.

**Decision:** Every operator write carries its own natural precondition instead of an `Idempotency-Key`. A proposal is created once per client attempt, keyed by a `client_token` unique to the proposal (a retried `POST` with the same token returns the same proposal); the decision is guarded by the proposal's `pending` state read under `SELECT … FOR UPDATE` (a second approve is `409 refused`); a reconciliation review refuses a line already reviewed; a poll is naturally safe because the sweeper reads the PSP before it writes (DECISIONS #20). Row locks and state preconditions do the work; there is no merchant-less `IdempotencyGuard`.

**Rejected:** extending the merchant `IdempotencyGuard` to operators.

**Reason:** The guard's key space is per merchant, and an operator does not act for a merchant. More importantly, every operator write already has a precondition that is stronger than a key: "this proposal is still pending", "this break is not yet reviewed", "this payment is still `unknown`". A key would be a second, weaker way to say the same thing and would need a scope (per operator, per merchant, global) that the existing guard does not model. The `client_token` on proposals exists only to make a retried create idempotent, not to authorize the change.

**Trade-off:** There is no generic safety net: every new operator write has to be designed with its own precondition, and a missing one is a bug a key would have hidden.
