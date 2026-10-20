# PayHub use cases and test coverage

> Every use case the docs promise ([OVERVIEW.md](OVERVIEW.md), [DOMAIN.md](DOMAIN.md), [DECISIONS.md](../DECISIONS.md)), checked against the code and specs. Then compared with what Stripe, Adyen, Checkout.com, PayPal, the Asian wallet providers and PCI DSS v4 / NIST 800-63B / OWASP ASVS expect. Audited 2026-10-20 by reading code and specs; the suite was not run.

**Status:**
- ✅ the behaviour is implemented and a spec asserts it
- 🟡 partial: implemented, but the test is indirect or misses an edge
- ⚪ implemented, with no test
- 🔴 bug, or the code contradicts the docs
- ⛔ not built
- 🚫 deliberately not built (a non-goal)

## 0. Status after the fixes (2026-10-20, branch `fix/use-case-coverage`)

**Fixed:**
- All 15 bugs in §1, test-first. The specs are in [TEST_CASES.md](TEST_CASES.md) §1–§2.
- Several partial captures now match the market: `final` flag, Stripe/Checkout.com defaults, Adyen-style events per capture.
- 9 more defects the code review found in the fixes themselves (TEST_CASES §4). The worst: a Kiripay refund that had already landed could be failed, and paid out twice.
- Every ⚪/🟡 test gap in TEST_CASES §3 now has a spec, including the DOMAIN.md walkthrough as a test.

**Verification:**
- 884 examples, 0 failures, 0 pending
- Sorbet clean, rubocop clean, frontend 26/26
- simulation seeds 1–20 green

Rows marked ✅ below are fixed or now fully tested.

**Still open:**

*Not part of the 15 bugs.* Each needs a product decision or a feature, not a test:

| ID | Gap | Why it is still open |
| --- | --- | --- |
| M7 | No list / revoke of other sessions | Feature (ASVS 7.5.2) |
| M11 | No re-invite; a removed member's email is blocked for every shop | The global unique email needs a product decision |
| M12 | Only 2 security emails; no authenticator reset | Feature |
| H8 | At-least-once / unordered delivery isn't documented for merchants | Docs |
| L4, M10 | A twin can point at a twin; the DB allows zero owners | Needs a DB constraint |
| L6 | Rate limit per key, not per merchant; the dashboard has no limit | Design choice |
| C6 | `pending` payments never reach the ops queue | Design choice |
| J5 | The Kiripay settlement skip is silent | Log line |
| K1 | A call-log row is lost if the caller's transaction rolls back | Design |
| — | Late wallet successes are listed for ops, but there is no in-product refund for them | Feature (M-4) |

*Decided (2026-10-20):* request tickets now follow Stripe and Checkout.com. A `validation_failed` 422 keeps no ticket, so a corrected retry with the same key goes through. Answers to requests that ran (2xx, or a 4xx like `invalid_state`) are still replayed for 24h. See DECISIONS #3, TC-A4-1 and TC-A4-2.

*Deliberately not built:* G5 (releasing a remainder at the PSP), disputes, PSP failover, and the rest of §9.

## 1. Bugs and contradictions, ranked by risk

Each one below has been checked against the code.

| # | Risk | Problem | Where | Fix direction |
| --- | --- | --- | --- | --- |
| 1 | 💰 double charge | Kiripay authorize is re-sent after a 404 lookup and on every 5xx retry. The comment relies on "the PSP's own idempotency", and Kiripay has none (DECISIONS #12). A crash after the PSP call but before the state is written also re-sends. | [resolve_unknown_payment.rb:19-23](../app/services/resolve_unknown_payment.rb#L19-L23), [authorize_payment_job.rb:19](../app/jobs/authorize_payment_job.rb#L19) | An adapter capability `idempotent_authorize?`. When it is false, look up by our reference before any re-send. |
| 2 | 💰 money stuck | A refund the PSP rejects is discarded while still `pending`. Its reservation is never released, and the sweeper re-drives it every 2 minutes. | [refund_payment_job.rb:16](../app/jobs/refund_payment_job.rb#L16) | Rejected → `failed` plus a void of the reservation plus `refund.failed`. |
| 3 | 💰 feature broken | A second partial capture is always refused: the first booking moves the payment to `captured`, and capture only accepts `authorized`. The specs never notice: they insert Capture rows directly, and the property and simulation specs swallow the 400. | [capture_payment.rb:13](../app/services/capture_payment.rb#L13), [book_capture.rb:36-38](../app/services/book_capture.rb#L36-L38) | Either allow capture from `captured` while remaining > 0, or document "one partial capture". The specs need to count accepted vs refused actions. |
| 4 | 💰 stuck forever | A Kiripay `requires_action` payment whose customer walks away never ends. There is no expiry, and the sweeper ignores that state. | [payment_state_machine.rb:21](../app/lib/payment_state_machine.rb#L21) | Expire it to `failed` after N minutes. Handle a late success (see §9, M-4). |
| 5 | 🔐 security | Rolling an **expired** API key revives it for the overlap window. Only the UI hides the button. | [api_keys_controller.rb:30](../app/controllers/dashboard/api/api_keys_controller.rb#L30), [api_key.rb:67](../app/models/api_key.rb#L67) | Look the key up with `.active`; refuse the roll otherwise. |
| 6 | 🛠 500 error | Every Kiripay cancel, and Nordpay `not_voidable`, raises `Rejected`, which no controller rescues. | [kiripay_adapter.rb:88](../app/adapters/kiripay_adapter.rb#L88), [v1/base_controller.rb:44](../app/controllers/v1/base_controller.rb#L44) | Add a `voidable?` capability (DECISIONS #9) checked before the call, and map Rejected to 4xx. |
| 7 | ✉️ lost letters | Redelivering a dead outbound event doesn't reset `attempts`, so one more failure kills it again. | [outbound_event.rb:52](../app/models/outbound_event.rb#L52) | Reset `attempts: 0` in `redeliver!`. |
| 8 | 📜 doc lie | `payment_transitions` has **no DB trigger**: append-only is enforced by Rails callbacks only. DOMAIN.md says "the database refuses edits and deletes". `ledger_entries` also lacks a TRUNCATE guard. | [structure.sql triggers](../db/structure.sql), [payment_transition.rb:20](../app/models/payment_transition.rb#L20) | Add the `append_only_guard` trigger (allowing the `most_recent` flip), or fix the doc. |
| 9 | 📒 books | The settlement job checks only over-settlement, so under-settlement is matched and booked. A line where net ≠ gross − fee raises `Unbalanced`, which isn't rescued: the run aborts and the line is lost. A second distinct line for a refund is reported as a "duplicate". | [settlement_reconciliation_job.rb:72-80](../app/jobs/settlement_reconciliation_job.rb#L72-L80) | Flag any amount ≠ the expected amount, rescue `Unbalanced` per line, and separate the two unique-index errors. |
| 10 | 🧾 audit | Refusals that aren't permission denials are never audited: 409/422, self-approve, double-approve, withdraw, step-up required, mode switch. The doc says the log records refusals. | [authorization.rb:114-124](../app/controllers/concerns/authorization.rb#L114-L124) | Audit in a `rescue_from`/`ensure` around actions. |
| 11 | 🛠 500 error | The same proposal `client_token` sent by a different operator gives an uncaught `RecordNotUnique`. | [proposals_controller.rb:24-27](../app/controllers/ops/api/proposals_controller.rb#L24-L27) | Rescue and return 409. |
| 12 | 📜 doc lie | DECISIONS #7 says optimistic `lock_version`; the code uses `with_lock`. The sweeper's StaleObjectError rescue is dead code. | [payment.rb:81](../app/models/payment.rb#L81) | Update DECISIONS #7. |
| 13 | 🧾 PCI | A PAN sent as `payment_method_token` is accepted and stored in plaintext. | [payments_controller.rb:89](../app/controllers/v1/payments_controller.rb#L89) | Reject anything that is Luhn-valid and 13–19 digits. |
| 14 | 📒 books | The webhook capture books `payment.amount_minor`, not the PSP's reported amount. That is safe only while Nordpay says "captured" only on full captures. | [process_inbound_event_job.rb:68](../app/jobs/process_inbound_event_job.rb#L68) | Book the PSP's `captured_minor`. |
| 15 | 🔁 starvation | Orphan inbound events are retried oldest-first with a limit, with no cap and no alert. This is the same backlog bug that DECISIONS #13 fixed for payments. | [stuck_payment_sweeper_job.rb:135](../app/jobs/stuck_payment_sweeper_job.rb#L135) | Use the same half-oldest/half-newest split, and alert after N tries. |

**Smaller items:**
- **Rate limit (L6):** it is per key, not per merchant as the comment says, and the dashboard has no throttle.
- **Test twin (L4):** a test twin can point at another twin.
- **Owner (M10):** the DB allows zero owners.
- **Invites (M11):** emails are unique globally and the index includes disabled users, so a removed person can never be re-invited.
- **Proposals (N6):** the reason and case reference stay editable at the DB level.
- **Walkthrough doc (G7):** DOMAIN.md walkthrough step 9 writes 2 outbound events, not 1.
- **Collect dialog (G5):** the CaptureDialog text promises a leftover-hold release that is not built.

## 2. Payment creation and idempotency

| ID | Use case | Status | Gap |
| --- | --- | --- | --- |
| A1 | EUR/GBP/USD payment → 202 pending, routed to Nordpay | ✅ | GBP and USD routing not asserted |
| A2 | VND/THB/IDR → Kiripay | ✅ | No test asserts `psp_name == "kiripay"` |
| A3 | Unsupported currency → 422 | ✅ | |
| A4 | Invalid amount (0, negative, float, string) | ✅ | 0, 25.5 and "2500" never sent through the API |
| A5 | Zero-decimal currency stored as-is | ✅ | No API test with VND 50000 |
| A6 | Reference saved before the PSP call; safe after a crash | ✅ | Nordpay only (see bug 1) |
| A7 | FX rate copied at creation | ✅ | No "new rate later, payment unchanged" test |
| A8 | Same key and body → replay, one payment | ✅ | Real-thread race tested |
| A9 | Same key, different body → 422 | ✅ | |
| A10 | In-flight duplicate → 409 | ✅ | Unit only, no request test |
| A11 | Keys scoped per merchant | ✅ | Guard level only |
| A12 | Key kept for 24h | ✅ | TTL value not asserted |
| A13 | Missing key → 400 | ✅ | |
| A14 | PAN never logged / never stored | ✅ | See bug 13 |
| A15 | Abandoned claim (>60s) can be re-taken | ✅ | |
| A16 | 4xx replayed; 5xx releases the key | ✅ | |
| A17 | Supported currency with no FX rate → 503 | ✅ | |

## 3. Authorization and unknown-state recovery

| ID | Use case | Status | Gap |
| --- | --- | --- | --- |
| B1 | Approve → authorized, plus `payment.authorized` in the same transaction | ✅ | |
| B2 | Decline → failed | ✅ | |
| B3 | requires_action → authorized / failed / expired | ✅ | Expiry not built (bug 4); the decline webhook is untested |
| B4 | Timeout → unknown; the charge is never re-sent | ✅ | |
| B5 | unknown dated from the first send | ✅ | |
| B6 | 5xx / connection error → retry; 4xx → discard | ✅ | Kiripay error mapping untested |
| B7 | Kiripay deduped by our reference | ✅ | Bug 1 |
| B8 | Job crash after the PSP call doesn't double-charge | ✅ | Bug 1 |
| B9 | Ordered by PSP time; stale rows recorded, not applied; one current row | ✅ | DB uniqueness never attacked directly |
| B10 | Illegal transitions refused | ✅ | |
| C1–C2 | Sweeper resolves unknown → authorized / failed | ✅ | |
| C3 | Backoff and check count | ✅ | |
| C4 | Sweeper vs webhook race | ✅ | Doc mismatch (bug 12); no race test |
| C5 | Half oldest / half newest scheduling | ✅ | SKIP LOCKED split untested |
| C6 | Long-unknown escalation | 🟡 | No escalation; `pending` payments never reach the ops queue |
| C7 | Ops resolves unknown by two-person proposal | ✅ | `unknown → authorized` path untested |
| C8 | Circuit breaker per PSP | ✅ | "Payments wait rather than fail over" inferred, not tested |
| C9 | Simulation | 🟡 | Its fake PSP deduplicates authorize and only plays Nordpay, so it cannot see bug 1 |

## 4. Capture, refund, cancel, expiry

| ID | Use case | Status | Gap |
| --- | --- | --- | --- |
| E1 | Full capture plus balanced ledger | ✅ | `payment.captured` event not asserted |
| E2 | Partial capture | ✅ | |
| E3 | Multiple partial captures | ✅ | Bug 3 |
| E4 | Capture > authorized → 422 | ✅ | |
| E5 | Capture refused in every non-authorized state | ✅ | Only `pending` tested |
| E6 | One pending capture at a time | ✅ | No thread race, no DB-index test |
| E7 | Read PSP total before send (double-charge fix) | ✅ | |
| E8 | Capture timeout → re-drive | ✅ | Sweeper capture re-drive untested |
| E9 | Capture/refund/cancel idempotency via v1 | ✅ | Only POST /v1/payments tested |
| E10 | Capability flags | ✅ | `partial_capture_unsupported` untested |
| E11 | Late `charge.captured` webhook is a no-op | ✅ | Nordpay path untested; see bug 14 |
| F1 | Full refund | ✅ | No single full refund; the default amount is untested |
| F2 | Partial → `part_refunded` → `refunded` | ✅ | |
| F3 | Over-refund refused | ✅ | |
| F4 | Concurrent €20 + €20 on €25 → one refused | ✅ | Real threads |
| F5 | Two-phase reservation | ✅ | |
| F6 | A refund settles once | ✅ | |
| F7 | Refund refused unless captured | ✅ | Only `authorized` tested |
| F8 | Refund reference before the call; timeout handling | ✅ | Rejected → bug 2 |
| F9 | Refund idempotency | ✅ | v1 replay untested |
| F10 | `refund.succeeded` / `refund.failed` events | ✅ | Never asserted |
| F11 | Dashboard refund: permission, step-up, audit | ✅ | Step-up only in e2e |
| G1 | Cancel authorized → canceled plus event | ✅ | API cancel event not asserted |
| G2 | Cancel refused when not authorized | ✅ | Only `captured` tested; Rejected → bug 6 |
| G3 | Auto-void after 6 idle days plus notify | ✅ | |
| G4 | Idle boundary | ✅ | Exactly-6-days not tested |
| G5 | Release leftover hold after partial capture | 🚫 | The UI text says otherwise |
| G6 | Void capability per PSP | ✅ | Bug 6 |
| G7 | DOMAIN.md walkthrough (rows per step, €15.00 balance) | ✅ | No test; the doc miscounts step 9 |

## 5. Messages: PSP webhooks in, shop webhooks out

| ID | Use case | Status | Gap |
| --- | --- | --- | --- |
| D1 | Valid webhook stored and applied | ✅ | Kiripay end to end only; nothing posts to `/v1/webhooks/nordpay` |
| D2 | Bad signature stored, alerted, never applied | ✅ | Nordpay request-level test missing |
| D3 | Same event ×5 → stored once | ✅ | Sequential, not concurrent |
| D4 | Out of order → no regression | ✅ | |
| D5 | Webhook before the payment exists → applied later | ✅ | Re-drive applying is not tested; bug 15 |
| D6 | PSP secret list | ✅ | |
| D7 | Webhook resolves unknown → authorized | ✅ | No deterministic test |
| H1 | Outbox written in the same transaction | 🟡 | Refund events untested |
| H2 | 2xx → delivered | ✅ | |
| H3 | Retry with backoff | ✅ | Timeout and `duration_ms` untested |
| H4 | Dead → resend (ops, shop) | ✅ | Bug 7 |
| H5 | Merchant secret rotation, 24h overlap | ✅ | A double rotation inside 24h drops the first secret |
| H6 | SSRF guard on save **and** on delivery | ✅ | The https-only rule and IPv4-mapped addresses untested |
| H7 | `/v1/events` polling | ✅ | |
| H8 | Tell merchants: at-least-once, unordered | ⛔ | Not documented; no sequence number |

## 6. Ledger and reconciliation

| ID | Use case | Status | Gap |
| --- | --- | --- | --- |
| I1 | Transfers sum to zero; alarm | ✅ | The alarm itself is untested |
| I2 | Append-only enforced by the DB | ✅ | Bug 8 |
| I3 | Balances derived (`GET /v1/balance`) | ✅ | |
| I4 | Manual correction only by two people | ✅ | Not via request; payment-scoped only |
| I5 | Property-based invariants | 🟡 | One payment, EUR, a PSP that always says yes |
| I6 | Accounts per merchant × currency × kind | ✅ | |
| J1 | Matched line → booked | ✅ | |
| J2 | Unmatched flagged | ✅ | |
| J3 | Amount mismatch flagged | ✅ | Bug 9 |
| J4 | Re-import harmless | ✅ | |
| J5 | Kiripay has no report | 🟡 | Silent skip; Kiripay receivable never clears |
| J6 | Breaks reviewed with a note | ✅ | |
| J7 | Drift checks (reservations, cache, PSP total) | ✅ | Only reservation drift is tested |
| K1 | PSP call log, redacted, 12 months | 🟡 | Lost if the caller rolls back; young-row delete refusal untested |

## 7. Merchant platform: keys, sign-in, roles

| ID | Use case | Status | Gap |
| --- | --- | --- | --- |
| L1 | sk_live / sk_test routing; prefix must match mode | ✅ | DB CHECK never exercised |
| L2 | Key shown once, digest only | ✅ | |
| L3 | Roll with overlap; revoke immediately; never delete | ✅ | Bug 5 |
| L4 | Test-twin invariant | 🟡 | Twin can point at a twin |
| L5 | Live and test reported separately | 🟡 | Balances not tested per mode |
| L6 | Rate limits | 🟡 | Per key; dashboard has none |
| L7 | Webhook endpoint settings | ✅ | |
| M1 | Password plus TOTP always | ✅ | |
| M2 | 10 failures → lock | ✅ | Non-atomic counter |
| M3 | TOTP not reusable | ✅ | Model level |
| M4 | Recovery codes | 🟡 | Second use not tested via request |
| M5 | 15-min idle, 12h absolute | ✅ | |
| M6 | Step-up for money and secrets | ✅ | Many actions untested at request level |
| M7 | List and revoke other sessions | ⛔ | Only "sign out here" |
| M8 | Email unique case-insensitively | ✅ | Global, includes disabled users |
| M9 | Role × action matrix | ✅ | No route→permission fixture: a wrong permission passes CI |
| M10 | One owner; transfer ownership | ✅ | DB allows zero owners |
| M11 | Invite, expire, accept, change role | 🟡 | No re-invite; a removed email is blocked forever |
| M12 | Security history and emails | 🟡 | Only 2 email types; no TOTP reset |
| M13 | Live/test mode switch | ✅ | Not audited |
| M14 | Audit success **and** refusals | ✅ | Bug 10 |
| M15 | CSV formula safety | 🟡 | Email starting with `=` not tested end to end |
| M16 | CSP | 🟡 | Only 2 directives tested |

## 8. Operators, oversight, demo

| ID | Use case | Status | Gap |
| --- | --- | --- | --- |
| N1 | Operators separate from merchants | ✅ | |
| N2 | Operator role matrix | ✅ | |
| N3 | Operator TOTP, lockout, step-up | ✅ | Step-up only in e2e; recovery code untested |
| N4 | Propose with reason and case reference | 🟡 | Ledger correction is API-only, no request spec |
| N5 | No self-approval (DB CHECK) | ✅ | |
| N6 | Immutable after submit; withdraw | 🟡 | Reason fields mutable; withdraw success untested |
| N7 | Double submit → one proposal | ✅ | Bug 11 |
| N8 | Reject | ✅ | Only "note required" tested |
| N9 | Apply fails → `failed` with error | ✅ | Error persistence not asserted |
| N10 | Apply writes transition plus outbox | ✅ | Outbox not asserted |
| N11 | Two approvers at once → one wins | ✅ | Real threads |
| N12 | Read-only impersonation, 30 min, case reference | ✅ | Stop impersonation untested |
| N13 | Ops queue and payment detail | 🟡 | `unknown` only |
| N14 | Resend dead event | ✅ | See bug 7 |
| N15 | Circuit view (reset by design: none) | ✅ / 🚫 | |
| N16 | Operator invite, role change, disable | ✅ | `POST /operators` untested |
| N17 | Audit append-only, 12 months, refusals | ✅ | Bug 10 |
| O1 | Demo reset deletes nothing | ✅ | "Nothing deleted" not asserted |
| O2 | One chaos run at a time | ✅ | Small race → 500 |
| O3 | Chaos run checks the PSP's records | ⚪ | CI only |
| O4 | Demo API | ✅ | |
| P1 | Health, metrics, tracing | ✅ | |

## 9. What the market does that PayHub doesn't (yet)

**Money movement.** Sources: Stripe, Adyen, Checkout.com, PayPal, Xendit, MoMo.

| ID | Market use case | Who | PayHub |
| --- | --- | --- | --- |
| M-1 | Auth validity per scheme: Visa MIT ≈ 5 days, CIT 7–10 days, MC 7–30 days | Stripe, Adyen | ⛔ One 6-day value (fine for a simulated PSP; wrong for a real acquirer) |
| M-2 | Capture fails days after success (CAPTURE_FAILED) | Adyen | ⛔ No reversing transfer |
| M-3 | Refund fails after success (REFUND_FAILED, `refund.failed`) | Adyen, Stripe | ⛔ |
| M-4 | Wallet succeeds after local expiry: accept or auto-refund | Xendit | ⛔ (needs bug 4 first) |
| M-5 | Negative balance / refund after payout | Stripe, Adyen | ⛔ No policy |
| M-6 | Hard declines never retried (Visa cat. 1, MC MAC 03/21) | Visa, MC | ⛔ |
| M-7 | Reversal when unknown can't be resolved | Adyen | ⛔ Stays unknown, goes to the ops queue |
| M-8 | Refund on a disputed payment → specific error | Stripe, Adyen | ⛔ Generic failure |
| M-9 | 3DS/SCA challenge, soft decline → retry with SCA | Stripe, Adyen | ⛔ (Nordpay has no 3DS) |
| M-10 | Incremental / extended authorization, over-capture | Adyen, Stripe | ⛔ |
| M-11 | Wallet capability matrix per wallet × country (partial refund, refund window) | PayMongo, PPRO | 🟡 Per PSP only |
| M-12 | Webhook replay window (timestamp tolerance) | Stripe | 🟡 Kiripay 5 min; Nordpay body-only |
| — | Disputes, chargebacks, PSP failover, bank payout matching | everyone | 🚫 Non-goals |

**Platform and operations.** Sources: Stripe, Adyen, PCI DSS v4, NIST 800-63B, OWASP ASVS. PCI requirement numbers are taken from secondary sources; check them against the official text.

| ID | Market use case | Who | PayHub |
| --- | --- | --- | --- |
| P-1 | Restricted / scoped API keys | Stripe, Checkout.com, Adyen | ⛔ Every key can move money |
| P-2 | Per-key IP allowlist | Stripe, Adyen | ⛔ |
| P-3 | List and revoke sessions (ASVS 7.5.2) | Stripe, ASVS | ⛔ (M7) |
| P-4 | MFA reset by an admin, a recovery path for the sole owner | Stripe | ⛔ |
| P-5 | Security emails for password, MFA and key changes | Stripe | 🟡 (M12) |
| P-6 | Disable accounts unused for 90 days; access review (PCI 8.2.6, 7.2.4) | PCI | 🟡 CSV export only |
| P-7 | Audit every refusal (PCI 10.2) | PCI | 🔴 (bug 10) |
| P-8 | Tamper-evidence, alert on logging failure (PCI 10.3, 10.7) | PCI | 🟡 Triggers, no alerting |
| P-9 | GDPR erasure vs append-only log (pseudonymous actor IDs) | GDPR Art. 17(3) | ⛔ No decision |
| P-10 | Per-account and per-endpoint limits; 429 reason header | Stripe | 🟡 (L6) |
| P-11 | Webhook endpoint auto-disable plus email to the merchant | Stripe | ⛔ |
| P-12 | Merchant approval rules (refund > X, new admin) | Stripe Approvals | ⛔ |
| P-13 | KYB before live keys; pause payments/payouts; terminate; reserves | Stripe | ⛔ |

## 10. Suggested order of work

1. **Stop money loss:** bugs 1, 2, 3, 4 and 14. Each one gets a failing spec first. Then teach the simulation a Kiripay-style PSP that doesn't deduplicate, and make it count refused actions.
2. **Security:** bugs 5, 10 and 13. Add the route→permission fixture (M9).
3. **Robustness:** bugs 6, 7, 9, 11 and 15.
4. **Make the docs true:** bugs 8 and 12, the G7 walkthrough as a spec, H8 merchant delivery guarantees, and G5 UI text.
5. **Fill the ⚪/🟡 test gaps**, starting with the money paths (§4, §5).
6. **Decide on market items:** M-2, M-3, M-5 and P-1 are the ones a reviewer is most likely to ask about.
