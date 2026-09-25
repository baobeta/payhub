# Internal Operator / Support / Back-Office Consoles at Payment Companies and Fintechs

Scope note: Payment companies publish very little about their *internal* admin consoles (Stripe, Adyen, Checkout.com, PayPal, Square, Xendit have nothing substantive public on this that I found). The best primary sources are Monzo (security and ops posts), Modern Treasury (ledger design), Pigment (impersonation, not a fintech but the clearest public design), Uber/Airbnb (reconciliation), PCI DSS summaries, and vendor material (Retool). Merchant-facing dashboards (e.g. Stripe's) are a useful proxy for what the internal ones show, since internal tools are usually a superset. Every item below is marked as documented (cited) or inferred.

## 1. What internal consoles show for support and ops (payment lookup, event timeline, raw PSP payloads, webhook attempts and replay, reconciliation breaks, stuck-payment queues)

### Takeaway
Public evidence covers case-centric views (Monzo), webhook delivery logs with manual resend (Stripe's merchant dashboard), and automated reconciliation that routes failures to a dead-letter queue for people to handle (Uber) or tracks each transaction's state end to end (Airbnb). I found no public screenshots or write-ups of a payment company's internal cross-merchant lookup or raw-PSP-payload viewer. Those features are common practice but come from inference, not documentation.

### Cited Findings
- Monzo builds its own customer-support tooling. A task/case view "summaris[es] and highlight[s] the key facts of the case to guide less experienced COps", maps the steps the agent must take (including third parties such as the police), and shows "the appropriate information" based on the agent's experience. — [Monzo, How we design the tools that power our customer support (2020)](https://monzo.com/blog/2020/11/11/customer-support-design)
- Monzo's Operations scope includes "the internal tools, systems and processes that their support team use every day", and it publishes a vision and principles for its "internal product". — [Monzo Internal Product](https://monzo.com/internal-product); [Monzo blog, customer support topic](https://monzo.com/blog/topic/customer-support)
- Monzo has since added an LLM "Ops Agent" and "Agent Chip" to its in-house operations tooling. — [Monzo Ops Agent](https://monzo.com/blog/engineering-the-future-of-customer-operations-the-monzo-ops-agent); [Building Agent Chip](https://monzo.com/blog/building-agent-chip)
- Stripe's merchant dashboard is a proxy for the webhook-replay pattern. Stripe retries delivery automatically "for up to three days with an exponential back off" in live mode. A person can click **Resend** on an event for up to 15 days, or up to 30 days through the CLI (`stripe events resend`). A manual resend does not cancel the automatic retries, even when it returns 2xx. — [Stripe Docs, Webhooks](https://docs.stripe.com/webhooks); [Stripe Docs, Process undelivered events](https://docs.stripe.com/webhooks/process-undelivered-events)
- Uber's settlement accounting system marks events that fail reconciliation "as unhealthy and submits them to the DLQ (Dead Letter Queue)". Successful events go on to the accounting engine. — [Uber, Advanced Settlement Accounting System](https://www.uber.com/us/en/blog/ubers-advanced-settlement-accounting-system/)
- Airbnb traces "the contents of every transaction through various payment states to ensure every piece of the payments cycle lands in a consistent state". It operates in 191 countries with 70+ currencies and 20+ processors. — [Airbnb Tech Blog, Measuring transactional integrity](https://medium.com/airbnb-engineering/measuring-transactional-integrity-in-airbnbs-distributed-payment-ecosystem-a670d6926d22) (full text was blocked by a 403; this comes from the search snippet)
- Nubank gives internal teams, including customer support agents, access to *sanitized* customer and transaction data through Metabase. — [Harvard D3 case on Nubank](https://d3.harvard.edu/platform-digit/submission/nubanks-data-driven-decision-making-democratizing-data-access-for-any-internal-team/) (secondary source)
- Wise's Business Operations Tooling team aims to "centraliz[e] data, simplif[y] workflows, and automat[e] time-consuming tasks" for ops staff. Its first phase uses Salesforce before building bespoke internal tools. — [Wise job posting, Engineering Lead, Business Operations Tooling](https://wise.jobs/job/engineering-lead-business-operations-tooling-in-tallinn-jid-2788)

### Inferences
- Unmatched reconciliation results and failed or stuck state transitions are usually pushed into an explicit queue (a DLQ or an exceptions list) that people work through, rather than being fixed silently. Uber documents this; it is inferred as general practice.
- An internal console is usually a superset of the merchant dashboard. If the merchant can see event logs, webhook attempts and a Resend button, operators can too, across all merchants. Replays are bounded by retention windows (Stripe: 15 or 30 days), and replaying does not change the automatic retry state.
- The design principle Monzo states, that internal staff are "customers" of an internal product, suggests showing the case (a summary plus a guided next step) rather than only raw tables.

### Gaps
- I found no public source from Stripe, Adyen, Checkout.com, PayPal, Square, Razorpay or Xendit describing their internal ops console: cross-merchant search, raw acquirer request/response views, or stuck-payment queues.
- I found no public metrics on stuck-payment SLAs or reconciliation-break triage times.

## 2. How manual interventions are controlled (maker-checker, reason codes, ticket references, JIT and break-glass access)

### Takeaway
Monzo documents multi-party authorisation both for code changes and for "sensitive actions by our customer operations team". It also documents break-glass access that pages security loudly and keeps full audit. Maker-checker for manual ledger corrections, fee or limit changes and large withdrawals is standard banking practice, but most of the evidence for it comes from secondary sources.

### Cited Findings
- Monzo: "Sensitive actions by our customer operations team and other parts of the company also require multi-party authorisation." — [Monzo, How we secure Monzo's banking platform (2022)](https://monzo.com/blog/2022/03/31/how-we-secure-monzos-banking-platform)
- Monzo: its change management policy requires "at least one other person to review a change", and this is enforced technically in the pipeline. Its internal deploy tool, Shipper, automates what would otherwise be a heavy change-management process. — [Monzo security post](https://monzo.com/blog/2022/03/31/how-we-secure-monzos-banking-platform); [Container Solutions on Monzo's platform](https://blog.container-solutions.com/how-monzos-opinionated-platform-and-tools-support-their-developer-experience)
- Monzo break-glass: backup access systems "trigger very loud alerts, and will immediately page security on-call engineers", "require multi-party authorisation if necessary", and keep "the same level of audit scope and ability to identify the user as using the regular system". Direct infrastructure access is limited to exceptional situations and goes through Teleport as an auditing proxy. — [Monzo security post](https://monzo.com/blog/2022/03/31/how-we-secure-monzos-banking-platform)
- Monzo runs a three-lines-of-defence model (first-line risk owners, second-line operational risk, third-line internal audit). Internal audit reviews "access control mechanisms and policies". Risk assessments come before changes, and a risk and control register is maintained. — [Monzo, How we manage technology risk (2023)](https://monzo.com/blog/2023/05/04/how-we-manage-technology-risk-at-monzo)
- In maker-checker, the "maker" initiates and a different "checker" approves or rejects. Suggested candidates for four-eyes include manual ledger corrections, large or manual withdrawals, treasury moves, and fee-schedule or limit changes. — [Wikipedia, Maker-checker](https://en.wikipedia.org/wiki/Maker-checker); [Fintech Engineering Handbook](https://w.pitula.me/fintech-engineering-handbook/) (practitioner handbook, secondary)
- ING describes the four-eye principle for transactions as an anti-fraud control. — [ING Wholesale Banking](https://www.ingwb.com/en/service/corporate-fraud/the-importance-of-the-four-eye-principle-for-transactions)
- Retool markets approval workflows and RBAC for sensitive Stripe actions taken from internal apps, and logs who performed each action (Stripe keeps its own API audit trail alongside). — [Retool Stripe integration](https://retool.com/integrations/stripe) (vendor marketing)

### Inferences
- The typical control stack is: RBAC scoped to a job function, then a four-eyes approval for money-moving or balance-changing actions (the approver must differ from the requester), then a mandatory free-text or coded reason plus a ticket or case ID, then an immutable audit event. Mandatory reason codes and ticket references are widespread practice, but **I found no fintech primary source that documents them explicitly**. Monzo's case-centric tooling implies that actions are tied to cases.
- Break-glass is designed to stay auditable while being deliberately noisy. The paging and the alert are the deterrent.

### Gaps
- There is no public documentation of time-boxed JIT elevation inside customer-ops consoles (as opposed to infrastructure access) at the named firms.
- There are no public thresholds (for example, "adjustments above X need a second approver").

## 3. Customer data access controls (impersonation or "view as", consent, access logging, PII masking)

### Takeaway
The documented patterns are these. Roles are scoped narrowly, and a support agent may hold "dozens" of expertise-specific roles (Monzo). Individual access to cardholder data must be logged (PCI DSS 10.2.1.1). Access is reviewed at least every six months (PCI 7.2.4). Impersonation should be read-only by default, time-limited, visibly flagged, consented to by the customer, and attributed to the operator on every request (Pigment's detailed write-up, which is not a fintech). Analysts get sanitized data (Nubank).

### Cited Findings
- Monzo: "Internal applications use role-based access controls where each role is scoped to a particular responsibility at the company". A support specialist may have "dozens of roles based on your area of expertise and training". Staff must use hardware tokens and a possession factor, partly to "enforce our policy on no credential sharing". Actions by people and service accounts are logged, "with the highest level of detail recorded on actions that potentially impact customer security". — [Monzo security post](https://monzo.com/blog/2022/03/31/how-we-secure-monzos-banking-platform)
- Monzo holds structured access-review sessions, audited at least yearly. — [Monzo security post](https://monzo.com/blog/2022/03/31/how-we-secure-monzos-banking-platform)
- Pigment's impersonation design (2026):
  - It issues a separate JWT carrying both the impersonated user's and the impersonator's identities, a read-only flag, and a 30-minute expiry.
  - The auth middleware rejects mutations with 403. Every endpoint must be explicitly tagged as allowed or blocked in read-only mode, and a build-time linter enforces the tagging.
  - Customers can revoke impersonation permission themselves ("no ticket, no negotiation").
  - Every session start is logged, and the impersonator's identity travels through every service request.
  - A dark border frames the screen while impersonating.
  — [Pigment Engineering, Impersonation Done Right](https://engineering.pigment.com/2026/04/08/safe-user-impersonation/)
- General guidance: impersonation should be "narrow, time-limited, and traceable". Users should be told when it starts and ends, get a "recent access" view, and be able to toggle approval. Impersonation events should not be buried in generic system logs. — [AppMaster blog](https://appmaster.io/blog/secure-admin-impersonation-controls-audit-scope) (vendor blog, secondary)
- Nubank exposes *sanitized* customer and transaction data to internal teams. Revolut's data platform validates access requests against governance models and prompts data owners to approve them. — [Harvard D3 on Nubank](https://d3.harvard.edu/platform-digit/submission/nubanks-data-driven-decision-making-democratizing-data-access-for-any-internal-team/); [Google Cloud, Revolut case study](https://cloud.google.com/customers/revolut-data)
- Stripe's merchant-side roles include a distinct "Support Specialist" role, alongside Owner, Administrator, Developer, Analyst and View Only. That is evidence of function-scoped roles at the merchant level. — [Stripe Docs, User roles](https://docs.stripe.com/get-started/account/teams/roles)

### Inferences
- A "view as merchant" feature in a payments console should be read-only by default, time-boxed, visibly flagged, and require a case reference. Any write should go through the normal maker-checker path, never through the impersonated session. This is inferred by applying Pigment's pattern together with PCI Req 10.
- Full PAN display should be absent entirely (tokenization, or showing only BIN and last 4) instead of being gated by a role. That keeps the console out of PCI scope. This is common practice; I found no fintech-specific primary source for it.

### Gaps
- I found no public description of Stripe's, Adyen's or Square's merchant-consent flow for support access to merchant accounts.
- I found no fintech primary source for "who viewed which customer" logging UX, such as surfacing views to the customer.

## 4. Manual ledger adjustments: compensating entries, never edits

### Takeaway
Ledgers are append-only. A correction is either a full reversal plus a new correct entry, or a single delta entry. The reason is that mutation destroys the evidence needed to explain discrepancies. Modern Treasury adds a nuance: for *pending* movements it discards and replaces entries rather than posting reversals, which keeps account histories readable.

### Cited Findings
- Modern Treasury: "if the data has been mutated, then the data is irreversibly destroyed and then becomes impossible to figure out what changed". It describes two correction strategies:
  - fully reverse, by creating an opposite-amount transaction and then a new correct one;
  - post a difference transaction that brings the total to the correct amount.
  It keeps mutable business objects (orders, payouts) separate from immutable ledger transactions, which remain "the ultimate source of truth". Its example is tracing "a $10 discrepancy in their $10,000 payout". — [Modern Treasury, Enforcing Immutability in your Double-Entry Ledger](https://www.moderntreasury.com/journal/enforcing-immutability-in-your-double-entry-ledger)
- In Modern Treasury's product, ledger entries are immutable. An update that affects balances *discards* the existing entries and creates new ones. They rejected reversal entries for pending changes because reversals make account history "messy": you "can't distinguish between debits that were client-initiated and debits that are generated by the ledger as reversals". — [Modern Treasury, How to Scale a Ledger Part V](https://www.moderntreasury.com/journal/how-to-scale-a-ledger-part-v); [MT Docs, Ledger Transaction object](https://docs.moderntreasury.com/platform/reference/ledger-transaction-object)
- Modern Treasury supports verifying prior ledger states through versioning. — [MT Docs, Verify Prior Ledger States](https://docs.moderntreasury.com/ledgers/docs/verify-prior-ledger-states)
- Uber forwards enriched financial events to an accounting engine, which persists the accounting transactions. Failed reconciliations go to a DLQ rather than being overwritten. — [Uber settlement accounting](https://www.uber.com/us/en/blog/ubers-advanced-settlement-accounting-system/)

### Inferences
- An operator "adjustment" in a console should create a new, balanced journal transaction that carries a reason, a link to the original transaction, the maker and the checker. It should never be an UPDATE of an amount. Marking an entry as operator-generated (as opposed to system- or client-initiated) answers MT's readability concern.

### Gaps
- I found no public detail on how Stripe, Adyen or Square model manual balance adjustments internally. Stripe exposes "adjustment" balance transactions to merchants, which suggests a compensating-entry model, but I did not verify this in this pass.

## 5. Regulatory drivers (SOX change controls, PCI DSS least privilege, segregation of duties, acquirer and regulator audits)

### Takeaway
PCI DSS v4.0 Req 7 requires need-to-know, RBAC-style least privilege and a six-monthly access review. Req 10 requires logging every individual access to cardholder data, with tamper protection, daily review and 12-month retention. UK banks (Monzo) run three-lines-of-defence with internal audit of access controls under FCA and PRA oversight. SOX-style change control appears in Monzo's mandatory second reviewer for changes.

### Cited Findings
- PCI DSS v4.0 Req 7: access to CDE components and cardholder data is limited to people whose job requires it. 7.2 requires RBAC or equivalent least privilege. 7.2.4 (new in v4.0) requires reviewing user accounts and privileges at least every six months. — [Teleport, PCI DSS 4.0 identity evidence](https://goteleport.com/blog/pci-dss-infrastructure-evidence/) (vendor summary)
- PCI DSS v4.0 Req 10: audit trails must reconstruct individual user access to cardholder data (10.2.1.1). Logs must be protected against tampering, reviewed daily, and retained for at least 12 months. — [HeroDevs, PCI DSS 4.0 Req 10](https://www.herodevs.com/blog-posts/pci-dss-4-0-requirement-10-how-to-log-and-monitor-all-access-to-system-components-and-cardholder-data); [PCI DSS Guide, Req 10](https://pcidssguide.com/pci-dss-requirement-10/) (secondary summaries)
- Monzo is regulated by the FCA and PRA. It uses three lines of defence, and its internal audit reviews access controls. — [Monzo tech risk post](https://monzo.com/blog/2023/05/04/how-we-manage-technology-risk-at-monzo); [Monzo Internal Audit Charter](https://monzo.com/investor-information/internal-audit-charter)
- Maker-checker enforces segregation of duties and gives governance and regulators an audit trail. — [Wikipedia, Maker-checker](https://en.wikipedia.org/wiki/Maker-checker)
- Retool's Ramp case study credits on-prem deployment "with access controls + audit logs" with making compliance requirements easier to meet. — [Retool customers](https://retool.com/customers) (vendor)

### Inferences
- The four-eyes rule on balance-affecting operator actions comes from segregation-of-duties expectations (SOX ITGC for public companies, bank-regulator SYSC-type systems-and-controls rules, and acquirer and scheme audits). It is less often an explicit rule text saying "operator adjustments need two people".
- Six-monthly access recertification (PCI 7.2.4) implies the console needs an exportable "who has which role" report.

### Gaps
- I did not pull primary PCI SSC, SOX (PCAOB AS 2201 ITGC) or FCA SYSC text. The summaries above come from secondary sources.
- I found no public acquirer audit checklists for merchant-of-record or PSP operator tooling.

## 6. How the tools are built (in-house vs Retool-style, separation from the merchant-facing app, separate auth and network)

### Takeaway
Large fintechs (Monzo, Stripe) build internal tools in-house on their own platforms. Monzo treats its internal product as a first-class product. Growth-stage firms often begin on a vendor or low-code tool (Wise starts on Salesforce; Ramp uses on-prem Retool) and move to bespoke tooling later. Staff access relies on hardware-token MFA and auditing proxies, separate from customer auth.

### Cited Findings
- Monzo builds internal tools and publishes "internal product" principles. Engineers make production changes through tooling (Shipper) rather than direct access. Staff authentication requires hardware tokens and a possession factor. — [Monzo Internal Product](https://monzo.com/internal-product); [Monzo security post](https://monzo.com/blog/2022/03/31/how-we-secure-monzos-banking-platform)
- Stripe has an internal AI platform that connects employees to "over 1,000 internal tools and skills", which shows a large in-house internal-tool estate. — [Stripe Dot Dev, Knowledge AI Platform](https://stripe.dev/blog/meet-stripes-knowledge-ai-platform)
- Wise's first phase is to "leverag[e] Salesforce to quickly deliver value before developing bespoke internal tools". — [Wise job posting](https://wise.jobs/job/engineering-lead-business-operations-tooling-in-tallinn-jid-2788)
- Ramp uses Retool on-prem with access controls and audit logs. Retool markets RBAC, approvals and audit logs for Stripe operations. — [Retool customers](https://retool.com/customers); [Retool Stripe integration](https://retool.com/integrations/stripe) (vendor)

### Inferences
- Common practice is to run the console as a separate app and origin from the merchant dashboard, behind SSO with hardware MFA and often a VPN or zero-trust proxy. It calls the same domain services through privileged, audited APIs, not direct DB writes, so that the domain invariants (state machine, ledger balancing) still hold. This is inferred from Monzo's "no direct infrastructure access" stance. I found no explicit public architecture diagram of a payment company's ops console.

### Gaps
- There are no public architecture write-ups for the Stripe, Adyen, Checkout.com, PayPal, Square, Razorpay or Xendit internal admin tools.
- I found no QCon or Money20/20 talk specifically on payment-ops console design in this pass.
