# PayHub UI: use cases

Source: `reports/Payment dashboard design standards.md` (market-standard research, 2026-09-25).
Scope: market standard, not enterprise. Three areas in one Vue app: **Merchant**, **Operator**, **Demo**.

**Backend column:** **Exists** means an API endpoint or service already does it. **Partial** means the data or logic exists but only in a console, rake task or table, with no endpoint. **New** means nothing exists yet.

## Actors

| Area | Actor | What they do | Why this role exists |
|---|---|---|---|
| Merchant | **Owner** | Everything, including transferring ownership | One accountable person per merchant (Stripe, Razorpay) |
| Merchant | **Admin** | Everything except ownership transfer | Day-to-day team and account management |
| Merchant | **Developer** | API keys, webhooks, test mode, read payments | Sees secrets, but cannot move money |
| Merchant | **Support** | Read payments, capture, cancel, refund | Reverses money, but sees no secrets and cannot grant access |
| Merchant | **Viewer** | Read only | Auditors, finance, stakeholders |
| Operator | **Support operator** | Search, read, poll PSP, resend events, view as merchant | Resolves tickets without being able to move money |
| Operator | **Ops operator** | Everything Support can do, plus propose transitions and ledger corrections | The "maker" |
| Operator | **Finance approver** | Approve or reject proposals | The "checker" |
| Operator | **Operator admin** | Manage operators and roles; cannot approve | Separates granting access from moving money |
| Demo | **Visitor** | Public, test mode only, no login | Shows the one rule holding up live |

The roles split four powers: **granting access**, **moving money out**, **reversing money**, and **seeing secrets** (PCI DSS Requirement 7, least privilege).

## Account and login (every signed-in user)

| ID | As a... | I want to... | So that / rule | Backend |
|---|---|---|---|---|
| A-01 | invited user | accept an invite, set a password and enrol an authenticator app | 2FA is mandatory (Adyen, Braintree, Xendit). Invites expire after 10 days (Stripe) | New |
| A-02 | user | sign in with password + 6-digit code | Account locks for 30 min after 10 failures (PCI 8.3.4) | New |
| A-03 | user who lost their phone | sign in with a one-time recovery code | Recovery codes are the market fallback. SMS is avoided because of SIM swapping | New |
| A-04 | user | be signed out after 15 min idle | PCI 8.2.8 | New |
| A-05 | user | get notified of a sign-in from a new device or IP | Stripe does this. Sent as real email (see Decisions) | New |
| A-06 | user | re-enter my code before a sensitive action | Step-up auth before key create/roll, invites, role changes, disabling 2FA (Stripe, Xendit) | New |
| A-07 | user | change my password and regenerate recovery codes | Self-service security hygiene | New |

## Merchant area

### Home and payments

| ID | As a... | I want to... | So that / rule | Backend |
|---|---|---|---|---|
| M-01 | any merchant role | see a home page with volume, balance and payments needing attention (`requires_action`, `unknown`) | Stripe's Home carries alerts first | Partial |
| M-02 | any merchant role | list and filter payments by state, currency and date | The Transactions list is universal | Exists |
| M-03 | any merchant role | export the filtered list to CSV | Every provider's list is exportable | New |
| M-04 | any merchant role | open a payment and see **one timeline**: transitions, PSP attempts, ledger postings, webhook deliveries | The universal payment-detail pattern. `unknown` shows *why* and which exits are pending | Partial (transitions exist; ledger and deliveries per payment are new) |
| M-05 | Support, Admin, Owner | capture an authorised payment, fully or partially | Button only shown in a valid state (Adyen) | Exists |
| M-06 | Support, Admin, Owner | cancel an authorised payment behind a named confirm button | Stripe steers to cancel over refund when uncaptured | Exists |
| M-07 | Support, Admin, Owner | refund a captured payment: full amount prefilled, partial allowed, remaining cap shown, reason required | Stripe's refund modal. **One Idempotency-Key per modal**, reused on retry | Exists (API reason is optional; the UI makes it required) |

### Balance and settlement

| ID | As a... | I want to... | So that / rule | Backend |
|---|---|---|---|---|
| M-08 | Viewer, Admin, Owner | see balance per currency: available, pending, reserved for refunds | Balances derive from the ledger (DECISIONS #5, #16) | Exists |
| M-09 | Viewer, Admin, Owner | see settled amounts and PSP fees per day | Money section of every dashboard (DECISIONS #18) | Partial (`settlement_lines` table, no endpoint) |

### Developers

| ID | As a... | I want to... | So that / rule | Backend |
|---|---|---|---|---|
| M-10 | Developer, Admin, Owner | create a named API key with a "where stored" note; see the secret **once** | Show-once (Stripe, Adyen, Razorpay). Needs the keys-table migration | New |
| M-11 | Developer, Admin, Owner | list keys with prefix + last 4, creator, created, **last used** | Stripe note field; Xendit "Last Used" | New |
| M-12 | Developer, Admin, Owner | roll a key and keep the old one working for now / 24h / 7 days | Zero-downtime rotation (Stripe 7d, Adyen 24h) | New |
| M-13 | Developer, Admin, Owner | revoke a key immediately; the row is kept for audit | Deactivate, never delete (Adyen) | New |
| M-14 | Developer, Admin, Owner | set the webhook endpoint URL | Needed before deliveries make sense | Partial (column exists, no endpoint) |
| M-15 | Developer, Admin, Owner | reveal and roll the webhook signing secret, with 24h dual signing | Stripe "Roll secret" (DECISIONS #15) | Partial (rake task exists) |
| M-16 | Developer, Admin, Owner | see each event's delivery attempts: status, HTTP code, attempt count, next retry | Stripe webhook delivery log | Partial (events list exists; attempts detail new) |
| M-17 | Developer, Admin, Owner | resend an event without cancelling automatic retries | Stripe Resend semantics | Exists |
| M-18 | Developer, Admin, Owner | switch between **test** and **live** data, with a persistent mode banner | Environment carried by the key prefix (`sk_test_` / `sk_live_`) | New |

### Team and security

| ID | As a... | I want to... | So that / rule | Backend |
|---|---|---|---|---|
| M-19 | Admin, Owner | invite a teammate by email with one role | Role chosen at invite time (all providers) | New |
| M-20 | Admin, Owner | change a member's role or remove them | Least privilege over time | New |
| M-21 | Owner | transfer ownership | Continuity (Razorpay Pseudo Owner) | New |
| M-22 | Admin, Owner | read the security history (logins, key and team changes) and export CSV | Stripe Security history. Append-only, kept 12 months (PCI 10.5.1) | New |

## Operator area

| ID | As a... | I want to... | So that / rule | Backend |
|---|---|---|---|---|
| O-01 | any operator | start on a **needs-attention queue**: `unknown` payments by age, dead-lettered events, reconciliation breaks | Exceptions go to queues, never silent fixes (Uber DLQ) | Partial (data exists) |
| O-02 | any operator | search payments across all merchants by id, `psp_reference` or merchant | Internal console is a superset of the merchant view | New |
| O-03 | any operator | see the merchant timeline **plus** inbound webhooks (signature valid or not) and PSP payloads with sensitive fields redacted | What support needs to resolve `unknown` | Partial (inbound webhook bodies are stored in `inbound_events.payload`; our own PSP calls will be stored in a new table, see Decisions) |
| O-04 | any operator | press **Poll PSP now** on a stuck payment | The primary, safe exit from `unknown` (DECISIONS #1, #13) | Exists (`poll_now`) |
| O-05 | any operator | redeliver a dead-lettered event with a reason | Same capability as M-17, plus an audited reason | Exists (merchant-scoped; needs operator route) |
| O-06 | Ops operator | **propose** a manual transition out of `unknown` with reason code, free text and case reference | Replaces the runbook's console command (DECISIONS #10) | Partial (console only) |
| O-07 | Finance approver | approve or reject a proposal; **cannot approve my own** | Maker-checker (Monzo multi-party authorisation) | New |
| O-08 | Ops operator | propose a ledger correction as balanced compensating entries linked to the original | Never edit the ledger (Modern Treasury) | New |
| O-09 | Finance approver | approve a ledger correction; posted entries are tagged `source: operator` | Keeps operator entries distinguishable from normal ones | New |
| O-10 | any operator | see each PSP's circuit breaker state | DECISIONS #17 | Partial (Redis only) |
| O-11 | any operator | review reconciliation and settlement breaks (`psp_drift`, unmatched lines) and mark them reviewed | DECISIONS #18 | Partial |
| O-12 | Support operator | **view as merchant**: read-only, 30 min, case reference required, banner on every screen | Pigment impersonation design. Writes are rejected server-side | New |
| O-13 | Operator admin | add operators and assign roles; I cannot approve anything | Separates granting access from moving money | New |
| O-14 | Operator admin | export "who holds which role" | Six-monthly access review (PCI 7.2.4) | New |
| O-15 | any operator | read the operator audit stream | Every operator action is attributable (PCI 10.2) | New |

## Demo area (public, test mode only)

| ID | As a... | I want to... | So that / rule | Backend |
|---|---|---|---|---|
| D-01 | visitor | create a test payment with a **magic input** that picks the outcome: success, decline, timeout then webhook, timeout needing an operator, wallet redirect | Stripe test cards, Braintree test amounts | Partial (simulators misbehave randomly; deterministic magic values are new) |
| D-02 | visitor | watch the payment move through a **live state-machine diagram** | Shows DECISIONS #10. **Note:** Action Cable is disabled, so start with polling | New |
| D-03 | visitor | approve a Kiripay wallet redirect as the "customer" | Makes `requires_action` tangible | Exists (simulator `_sim` endpoint) |
| D-04 | visitor | start a small chaos run and watch invariants hold: no double charge, no over-refund | The README's headline, made live | Partial (`chaos:run` rake task) |
| D-05 | visitor | see ledger totals where every transfer nets to zero | Shows the double-entry ledger (DECISIONS #5) | Partial |
| D-06 | visitor | reset the demo data | Stripe "Delete test data", Braintree "Purge Test Data" | New |

## Cross-cutting rules

- **Every UI write sends an Idempotency-Key**, created once per modal and reused on retry (DECISIONS #3).
- **Every sensitive action writes an append-only audit event**: actor, action, target, IP, user agent, result, time (PCI 10.2.2).
- **No card numbers anywhere.** Brand and last 4 only; customer contact details masked (keeps the UI out of PCI card-data scope).
- **Buttons appear only in valid states.** The server still enforces the state machine.
- **The existing `/v1` API does not change**, except key lookup moving to the new keys table.

## Deliberately skipped (enterprise only)

Custom roles, SSO/SCIM, organisations, multiple sandboxes, restricted keys, publishable keys, IP allowlists, audit API, passkeys, break-glass access, approval amount thresholds, helpdesk integration, per-key request log.

## Decisions

1. **Store payhub's own PSP calls.** A new append-only table records each outbound PSP call: payment, operation (authorize, capture, refund, status poll), redacted request, HTTP status, redacted response body, latency, and outcome. A **timeout is recorded too, with no response**, because that row is the evidence behind every `unknown` payment. Card tokens and secrets are removed before the row is written. Feeds O-03.
2. **Real email, caught locally.** Re-enable Action Mailer and send invites (A-01, M-19) and new-device alerts (A-05) through `deliver_later` on Sidekiq. In development and in docker compose, SMTP points at a **MailCatcher** service (SMTP on port 1025, web inbox on port 1080), so every email can be opened and checked without leaving the machine. Mailer specs assert on `ActionMailer::Base.deliveries`.
3. **Live updates: polling first** (confirmed 2026-09-25), behind one Vue composable so Action Cable can replace it later. Revisit if the demo needs per-event streaming.
