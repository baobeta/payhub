# API key management and test vs live (sandbox) mode across payment platforms

Scope: Stripe, Adyen, Checkout.com, Braintree/PayPal, Square, Razorpay, Xendit. Sources fetched September 2026 unless noted. Stripe docs were the richest source; the other providers' pages were read through a summarizing fetch tool, so exact wording on those pages may differ slightly from the quotes below.

## 1. What key types exist, and what the prefixes are for

### Takeaway
Every platform splits credentials into a **client-safe identifier** (publishable/public/client key; it can only tokenize) and a **server-only secret**. Mature platforms add **scoped/restricted secrets** (Stripe RAKs, Xendit per-product None/Read/Write, Checkout.com scoped keys + OAuth, Adyen credentials with roles + IP/origin allowlists). Webhook signing secrets are always a separate credential. Prefixes that name the environment and key type (`sk_live_`, `pk_test_`, `rk_live_`, `sk_sbox_`, `rzp_test_`, `xnd_production_`, `test_`/`live_` client keys, `sandbox_` tokenization keys) make keys identifiable. That serves two purposes: secret scanners can match them with few false positives, and humans and code can tell test keys from live keys at a glance.

### Cited Findings
**Stripe**
- Key types: Publishable `pk_...` (safe to expose; "can identify your account and create tokens or PaymentMethods ... but it can't perform sensitive operations such as creating charges or reading account data"), Restricted `rk_...` ("permissions you control... Create as many RAKs as you want and assign them to different parts of your application"), Secret `sk_...` ("unrestricted permissions on all Stripe APIs... we don't recommend using secret keys for new use cases... recommend migrating secret key usage to RAKs"), Organization `sk_org_...` for multi-account orgs. There are also "managed API keys" that hosting platforms issue and rotate for you — [Stripe API keys](https://docs.stripe.com/keys)
- Prefixes by environment: sandbox `pk_test_`, `rk_test_`, `sk_test_`; live `pk_live_`, `rk_live_`, `sk_live_` — [Stripe API keys](https://docs.stripe.com/keys)
- "Webhook signing secrets aren't API keys—they're per-webhook secrets"; they start with `whsec_` — [Stripe API keys](https://docs.stripe.com/keys); [Stripe webhooks](https://docs.stripe.com/webhooks)
- A restricted key can be tagged as belonging to an autonomous AI agent. Agent-tagged keys "are automatically subject to approval rules", which require a reviewer to approve payouts, refunds and account configuration changes (new, 2025-2026) — [Stripe API keys](https://docs.stripe.com/keys)
- Access policies (which replaced "IP address restrictions") can limit a key to IPv4/CIDR ranges, or with "Advanced" rules by ASN, country, and blocked sources (anonymous VPNs, public proxies, residential proxies, Tor). Stripe "blocks the request and notifies you", and recommends access policies on all live keys — [Stripe API keys](https://docs.stripe.com/keys)

**Adyen**
- An API credential has a username (`ws_123456@Company.[YourCompanyAccount]`), an API key, and **roles** (permissions). It can be scoped to the company account plus all merchant accounts, or restricted to specific account groups. Allowed IP ranges can be set so "only requests originating from that range will be permitted." — [Adyen API credentials](https://docs.adyen.com/development-resources/api-credentials/)
- Adyen recommends separate credentials per channel (for example online vs point-of-sale, unreferenced refunds, separate ecommerce/shipping systems) — [Adyen API credentials](https://docs.adyen.com/development-resources/api-credentials/)
- Client key: a 32-char string with a human-readable environment prefix (`test_...` / `live_...`). It is bound to **allowed origins**, which support wildcards (`https://*.example.org`) and must be https in live. "You can add or remove allowed origins without needing to generate a new client key." — [Adyen client-side authentication](https://docs.adyen.com/development-resources/client-side-authentication/)
- Webhooks use a separate HMAC key, optionally plus Basic auth or OAuth 2.0 to your server — [Adyen configure webhooks](https://docs.adyen.com/development-resources/webhooks/configure-and-manage/)

**Checkout.com**
- Public keys are for client-side tokenization (Flow, Google Pay). Secret keys are for server-to-server calls. Server auth can also use **access keys via OAuth 2.0 client credentials** — [Checkout.com manage API keys](https://www.checkout.com/docs/developer-resources/api/manage-api-keys)
- Sandbox prefixes are `pk_sbox_` / `sk_sbox_`; production uses `pk_` / `sk_`. Keys are sent as `Authorization: Bearer sk_sbox_...` — [Checkout.com API keys](https://www.checkout.com/docs/developer-resources/api/manage-api-keys/api-keys)
- Merchants can use one universal key or several keys with restricted scopes. Checkout.com suggests one processing channel per key and separate keys for payments vs disputes. Only Account owners can edit or delete keys — [Checkout.com API keys](https://www.checkout.com/docs/developer-resources/api/manage-api-keys/api-keys)

**Braintree / PayPal**
- Braintree credentials are a merchant ID, public key and private key. Client tokenization keys carry a `sandbox_` prefix in sandbox — [Braintree testing](https://developer.paypal.com/braintree/docs/reference/general/testing)
- PayPal REST apps use a client ID + secret, issued separately for sandbox and live — [PayPal sandbox](https://developer.paypal.com/tools/sandbox/)

**Square**
- Access tokens and app credentials are environment-specific: "account credentials and resources from one environment cannot be used with or accessed from the other" — [Square sandbox](https://developer.squareup.com/docs/devtools/sandbox/overview)

**Razorpay**
- Key ID + Key Secret are sent with HTTP Basic auth. Keys differ between Test mode and Live mode — [Razorpay authentication](https://razorpay.com/docs/api/authentication/)

**Xendit**
- Each account gets a public key pair (test + live) and **zero secret keys by default**; you create secret keys as needed. Public keys "only have the power to tokenize Cards." Secret keys have per-product permissions: None / Read / Write — [Xendit API keys](https://docs.xendit.co/docs/api-keys)
- Prefixes: `xnd_production...` (live secret) and `xnd_development...` (test secret) — [Xendit Help Center](https://help.xendit.co/hc/en-us/articles/16516398053273-What-is-API-Key-and-How-Do-I-Create-Them)

**Why prefixes exist**
- GitHub asks partners in its secret scanning partner program for patterns with "a uniquely defined prefix" and "high entropy random strings" to reduce false positives. When GitHub finds a match in public code, it POSTs the token, type and location to the partner, and the partner revokes the token and notifies the user — [GitHub secret scanning partner program](https://docs.github.com/en/code-security/secret-scanning/secret-scanning-partnership-program/secret-scanning-partner-program)
- Stripe's security team "watches for exposed customer data — including API keys — across repositories, package registries, websites, and forums. If we find a secret key, we alert its owner and may invalidate it automatically." — [Stripe Support: compromised keys](https://support.stripe.com/questions/protecting-against-compromised-api-keys)
- Secondary sources say Stripe is a GitHub secret scanning partner, but that coverage is limited: public repositories only, nothing in build logs, and there is a window between the push and detection — [Rafter blog](https://rafter.so/blog/secrets/github-secret-scanning-setup-limitations) (secondary; not confirmed on Stripe's own pages)
- Test-card numbers are "rejected if you accidentally use them with live API keys". So the live/test marker in the key decides which environment a request goes to, independent of what the Dashboard is showing ("Being in a sandbox in the Dashboard doesn't affect your integration code. Your test and live mode API keys affect the behavior of your code.") — [Stripe testing](https://docs.stripe.com/testing); [Stripe testing use cases](https://docs.stripe.com/testing-use-cases)

### Inferences
- The market standard is a three-part split: publishable key, scoped secret, and full secret (discouraged). Stripe now pushes RAKs as the default, and Xendit ships with no secret keys at all. A new platform should default to least-privilege keys.
- The environment is encoded in the key itself, so one API host can route requests (Stripe, Checkout.com, Razorpay, Xendit use the same host for both environments), and a leaked key is immediately recognizable as test or live.
- Adyen and Square put the environment in the hostname instead (checkout-test.adyen.com vs a merchant-specific live prefix; connect.squareupsandbox.com vs connect.squareup.com), which gives two layers of separation.

### Gaps
- No primary Stripe blog post was found explaining why Stripe chose the `sk_live_` prefix design. The rationale above comes from GitHub partner guidance and Stripe's leak-response page.
- I did not verify exact Razorpay key prefixes (`rzp_test_` / `rzp_live_`) from a primary page in this session; they are widely reported but the auth page summary did not quote them.
- Whether Checkout.com, Adyen, Razorpay and Xendit are GitHub secret scanning partners was not verified. GitHub's supported-patterns list would confirm it.

## 2. How secrets are shown, stored, rotated, revoked and audited

### Takeaway
The market pattern is: **show once**, have the user save the key to a vault, allow **rolling rotation with an overlap window** (Stripe up to 7 days for API keys and 24h for webhook secrets; Adyen 24h; Razorpay immediate or 24h), expire or deactivate immediately on compromise, and offer **per-key usage visibility** (Stripe per-key request logs; Xendit "Last Used"). Stripe adds step-up verification (an email/SMS code) before creating a secret key, a free-text note field for "where I stored this key", and automatic limits on keys that have not been used for payouts or transfers in a long time.

### Cited Findings
- Stripe: creating a secret key requires a verification code sent by email or text. After creation you "Save the key value. You can't retrieve it later," and then "Add a note" with the location where you saved it. A live key you created yourself cannot be revealed again. Only Stripe-generated keys (default secret, scheduled-rotation keys) can be revealed later. In sandbox "you can always see all of your API keys." Publishable keys are always shown — [Stripe API keys](https://docs.stripe.com/keys)
- Stripe rotation: "Rotating an API key revokes it and generates a replacement key that's ready to use immediately." You can schedule rotation. "When you rotate a key in the Dashboard, both the old and new keys work for up to 7 days." Before expiring the old key, Stripe advises checking its request logs and expiring only "after its request volume has been at zero for a few hours or days." — [Stripe API keys](https://docs.stripe.com/keys)
- Stripe expiry: once expired, a key's calls fail with an authentication error. Publishable keys cannot be expired — [Stripe API keys](https://docs.stripe.com/keys)
- Stripe dormant-key limits: a key "might have its access limited if it hasn't been used to create transfers, payouts, or update payout destinations for over 180 days". The user can "Restore access" — [Stripe API keys](https://docs.stripe.com/keys)
- Stripe audit: every key has a "View request logs" action that opens Workbench request logs filtered to that key — [Stripe API keys](https://docs.stripe.com/keys)
- Stripe recommends rotating keys when team members leave, when a key is compromised, or on a fixed schedule. It suggests a secrets vault ([AWS auto-rotation example](https://stripe.dev/blog/securing-stripe-api-keys-aws-automatic-rotation)) and not sharing keys over email or chat — [Stripe API keys](https://docs.stripe.com/keys)
- Adyen: "You cannot copy the API key again after you leave the page." A new key "becomes active immediately. The previous key remains active for 24 hours", and the user can reset or end that grace period. Credentials "cannot be deleted but can be deactivated", which takes effect immediately — [Adyen API credentials](https://docs.adyen.com/development-resources/api-credentials/)
- Razorpay: the Key Secret is shown only once ("never displayed again on the Dashboard"; download it at generation). You can regenerate with "immediate deactivation or 24-hour delayed rollover." — [Razorpay authentication](https://razorpay.com/docs/api/authentication/)
- Xendit: creating a key requires re-entering your password. Xendit recommends deleting unused keys "using 'Last Used' metadata", revoking compromised keys immediately, regenerating every 6-12 months, redacting keys from logs, and using a Request-ID rather than a key in support tickets — [Xendit API keys](https://docs.xendit.co/docs/api-keys)
- Checkout.com: only Account owners can edit or delete keys. Checkout.com recommends a password manager — [Checkout.com API keys](https://www.checkout.com/docs/developer-resources/api/manage-api-keys/api-keys)

### Inferences
- Showing a key only once implies the provider stores a hash, or at least does not display the key again. None of the fetched docs say "hashed" explicitly. Stripe's exception, that Stripe-generated live keys can be revealed, implies those particular keys are stored retrievably (probably encrypted).
- The overlap window is the core "roll key" feature: rotation becomes a zero-downtime deploy rather than an outage. Per-key request logs let users confirm the old key has stopped being used before expiring it.
- A "note: where is this stored" field is a cheap UI feature that helps users find where a key lives when it has to be rotated.

### Gaps
- No provider page explicitly confirmed hashing of stored secrets.
- Exact "last used" timestamp display in Stripe's key list was not confirmed. Only the request logs link was.
- Checkout.com key expiry/rotation and IP allowlisting details were not found in the fetched pages.

## 3. How test mode / sandbox works and how separated it is

### Takeaway
There are two models. (a) **Same account, toggled mode, with keys carrying the environment**: Stripe test mode, Razorpay, Xendit, and Checkout.com's same-style prefixes. (b) **Fully separate environments/accounts** with a different login, dashboard and hostname: Adyen test vs live Customer Area, PayPal/Braintree sandbox, Square sandbox. Stripe has moved from (a) toward (b) with **Sandboxes**: up to 5 isolated environments per account, with settings copied from live when a sandbox is created and separate access control. Stripe now recommends these over the legacy test mode, which shares settings with live. Objects, keys and webhook secrets never cross environments anywhere. Every platform provides deterministic "magic" test inputs: card numbers, amounts, cardholder names or nonces.

### Cited Findings
**Stripe**
- "Each mode has its own set of API keys, and objects in one mode aren't accessible to the other. For example, a sandbox product object can't be part of a live mode payment." — [Stripe API keys](https://docs.stripe.com/keys)
- Test mode sandbox vs general sandboxes: test mode is one per account and cannot be deleted, it grants all users the same roles as live, and it shares settings with live ("You can't test many settings independently"). General sandboxes: "up to five" (test mode not counted), Private / Developer / All-team-members access levels, users can be invited to sandboxes only, settings are "isolate[d] completely... Copy settings from live mode at creation time", they can be deleted, and they support API v2 — [Stripe testing use cases](https://docs.stripe.com/testing-use-cases)
- Warning: "If you change settings in the Dashboard while in the test mode sandbox, you might also change them in live mode." — [Stripe testing use cases](https://docs.stripe.com/testing-use-cases)
- Stripe recommends "separate sandboxes for local development and continuous integration (CI) so automated tests don't affect your settings or data." Coding agents can provision an anonymous sandbox via `stripe sandbox create` with "No account registration required." — [Stripe sandboxes](https://docs.stripe.com/sandboxes)
- Sandbox limits: no IC+ pricing tests, no linking of Connect platform sandboxes to connected-account sandboxes. Identity performs no checks, and Connect account objects don't return sensitive fields. No customer emails by default. There is a "Delete test data" button — [Stripe sandboxes](https://docs.stripe.com/sandboxes); [Stripe testing use cases](https://docs.stripe.com/testing-use-cases)
- Webhook secrets differ per mode: "If you use the same endpoint for both test and live API keys, the secret is different for each one." Sandbox retries are 3 attempts over a few hours; live retries continue for up to 3 days — [Stripe webhooks](https://docs.stripe.com/webhooks)
- Magic values: `4242 4242 4242 4242` succeeds. Declines: `4000000000000002` generic, `...9995` insufficient_funds, `...0069` expired, `...0127` incorrect_cvc, `...0119` processing_error. 3DS: `4000002500003155` (authenticate unless set up), `4000002760003184` (always authenticate). Radar: `4100000000000019` always blocked. Disputes: `4000000000000259`. Stripe also offers PaymentMethod shortcuts (`pm_card_visa`, `pm_card_visa_chargeDeclined`) "for PCI compliance", ACH test accounts, and microdeposit amounts — [Stripe testing](https://docs.stripe.com/testing)
- The Services Agreement "prohibits testing in live mode using real payment method details" — [Stripe testing](https://docs.stripe.com/testing)

**Adyen**
- Test and live credentials must be generated separately in the test and live Customer Areas. Live uses a merchant-specific URL prefix — [Adyen API credentials](https://docs.adyen.com/development-resources/api-credentials/)
- Endpoints: test `https://checkout-test.adyen.com/...`; live `https://[random-hex]-[Company]-checkout-live.adyenpayments.com/checkout/...`. The per-merchant hostname exists to "improve service robustness and availability", allowing "alternative routing to backup infrastructure" — [Adyen live endpoints](https://docs.adyen.com/development-resources/live-endpoints/)
- "Adyen does not provide a 'copy' function for moving your webhook configurations from the test environment to the live environment", and the live HMAC key "is different from the HMAC key from your test Customer Area." — [Adyen configure webhooks](https://docs.adyen.com/development-resources/webhooks/configure-and-manage/)
- Magic values: set `paymentMethod.holderName` (for example `DECLINED`, `CARD_EXPIRED`, `FRAUD`) or `additionalData.RequestedTestAcquirerResponseCode` (for example `2`, `6`, `20`) to force 40+ refusal reasons. Redirect methods use a simulator instead — [Adyen test result codes](https://docs.adyen.com/development-resources/testing/result-codes/)

**Checkout.com**
- The sandbox has its own keys (`_sbox_`). Magic values: card `4544249167673670` returns 20051 insufficient funds, `4111111111111129` returns 20001; amount `101` with `4242424242424242` returns 20051. Dedicated 3DS test cards exist. Sandbox payments are stored for 30 days max — [Checkout.com response code testing](https://www.checkout.com/docs/testing/response-code-testing)

**Braintree / PayPal**
- Braintree: "The sandbox is an entirely separate environment from your production account." It has a separate merchant ID, keys and login at sandbox.braintreegateway.com, and nothing transfers to production, including processing options and recurring billing settings — [Braintree testing](https://developer.paypal.com/braintree/docs/reference/general/testing)
- Braintree magic amounts: $0.01–$1,999.99 authorized, $2,000–$2,999.99 processor declined, $3,000–$3,000.99 failed, $5,001.00 gateway rejected. Nonces such as `fake-valid-nonce` and `fake-three-d-secure-visa-full-authentication-nonce`. Fraud cards: `4000111111111511` rejected, `4111140000000002` review. There is a "Purge Test Data" setting — [Braintree testing](https://developer.paypal.com/braintree/docs/reference/general/testing)
- PayPal sandbox: a "self-contained, virtual testing environment." You create fictional personal and business sandbox accounts, use sandbox endpoints, and use separate REST client ID/secret. It supports negative testing — [PayPal sandbox](https://developer.paypal.com/tools/sandbox/)

**Square**
- Sandbox base URL `connect.squareupsandbox.com` vs production `connect.squareup.com`. Up to 10 extra sandbox test seller accounts, each with a sandbox Dashboard. Free, unlimited calls. No hardware/POS, Restaurants, Invoices app, Sites API, or physical gift cards — [Square sandbox](https://developer.squareup.com/docs/devtools/sandbox/overview)

**Razorpay / Xendit**
- Razorpay: Test Mode simulates transactions, and Live Mode processes real payments "after KYC activation" — [Razorpay authentication](https://razorpay.com/docs/api/authentication/)
- Xendit: a dashboard toggle between "Test Mode" (fictional money) and "Live Mode", with keys generated per mode. "Use only your test API keys for testing... This ensures that you don't accidentally create or modify live transactions." — [Xendit Help Center](https://help.xendit.co/hc/en-us/articles/16516398053273-What-is-API-Key-and-How-Do-I-Create-Them)

### Inferences
- The industry trend (Stripe 2024-2026) is away from a single toggle that shares settings with live, toward multiple isolated, access-controlled sandboxes that clone live settings. The shared-settings toggle caused accidental live changes, and it cannot support separate dev, CI and staging environments.
- Magic values come in three styles: card number (Stripe, Checkout.com), amount (Braintree, Checkout.com), and a field value such as cardholder name or a test code (Adyen). Opaque test tokens (`pm_card_*`, `fake-*-nonce`) let server-side tests avoid handling raw PANs at all.

### Gaps
- Square and PayPal test-card and magic-value specifics were not fetched.
- Whether Razorpay/Xendit test-mode webhooks use separate secrets was not confirmed.
- "Timeout" simulation values were not found for any provider except Adyen's broad refusal list. Stripe's processing_error is the closest.

## 4. Why platforms separate environments this way

### Takeaway
The stated reasons are **safety**: no real money moves, and live transactions cannot be created by accident. **Least privilege and access control** come next: agencies and CI can get sandbox-only access. Then **risk and compliance gating**: live access follows KYC or a go-live checklist. And **PCI scope**: publishable keys and test tokens keep card data away from merchant servers. Separate hostnames (Adyen) also serve availability.

### Cited Findings
- Stripe: sandboxes let you "experiment with new features without affecting your live integration"; you can "invite another user, such as an implementation partner or design agency... without providing them access to your live mode data" — [Stripe sandboxes](https://docs.stripe.com/sandboxes)
- Stripe: switching keys "is only one step. Review the full go-live checklist" — [Stripe API keys](https://docs.stripe.com/keys)
- Stripe recommends distinguishing staging and production keys with different access policies — [Stripe API keys](https://docs.stripe.com/keys)
- Razorpay gates live mode behind KYC activation — [Razorpay authentication](https://razorpay.com/docs/api/authentication/)
- PayPal: separate credentials prevent "accidental live transactions during development" — [PayPal sandbox](https://developer.paypal.com/tools/sandbox/)
- Xendit: test keys ensure "you don't accidentally create or modify live transactions" — [Xendit Help Center](https://help.xendit.co/hc/en-us/articles/16516398053273-What-is-API-Key-and-How-Do-I-Create-Them)
- PCI: Stripe recommends using PaymentMethod IDs instead of raw card numbers "for PCI compliance". Publishable keys can only tokenize — [Stripe testing](https://docs.stripe.com/testing); [Stripe API keys](https://docs.stripe.com/keys)
- Adyen per-merchant live hostnames exist for robustness and failover routing — [Adyen live endpoints](https://docs.adyen.com/development-resources/live-endpoints/)

### Inferences
- Separate accounts (Adyen, Braintree, Square) give the strongest isolation: a compromised test login gives nothing in live. The cost is manual duplication of config, for example Adyen has no webhook copy. Stripe's "copy settings from live at creation" is a compromise between the two.
- A going-live review (KYC, checklist) lines up with test/live separation. Test access is instant and self-serve, which helps developer onboarding. Live access is gated by underwriting.

### Gaps
- No primary source explicitly cites PCI DSS scope reduction as the reason for the test/live split itself. PCI arguments are documented for client-side tokenization, not for environment separation.
- Adyen's live-account application and review process was not fetched (the get-started URL returned 404).

## 5. Webhook endpoint management UI

### Takeaway
The standard UI has one signing secret per endpoint per environment, revealed on demand, and a **roll secret** action with an overlap window during which the provider signs with both secrets (Stripe up to 24h). There is a per-endpoint delivery log with status and next retry, **manual resend** from the dashboard, a **test/send-test-event** button, and retries with exponential backoff. Signatures include a timestamp to protect against replay attacks.

### Cited Findings
- Stripe: up to 16 endpoints per account, HTTPS required in live, TLS 1.2+. Each endpoint has a signing secret (`whsec_`) shown via "Reveal secret" — [Stripe webhooks](https://docs.stripe.com/webhooks)
- Stripe "Roll secret": expire immediately or "delay its expiration for up to 24 hours... During this time, multiple secrets are active for the endpoint. Stripe generates one signature per secret." — [Stripe webhooks](https://docs.stripe.com/webhooks)
- Stripe signature format: `Stripe-Signature: t=...,v1=...`, HMAC-SHA256 over `timestamp.payload`. Receivers should ignore non-`v1` schemes to prevent downgrade attacks and use constant-time comparison. The default timestamp tolerance is 5 minutes against replay ("Don't use a tolerance value of 0"). Every retry gets a new timestamp and signature — [Stripe webhooks](https://docs.stripe.com/webhooks)
- Stripe "Event deliveries" tab: each event shows Delivered / Pending / Failed, the HTTP status, and the next retry time. Manual **Resend** in the Dashboard works for up to 15 days after the event; the CLI `stripe events resend` works for 30 days. A manual resend does not cancel automatic retries. Automatic retries run up to 3 days in live and 3 times over a few hours in sandbox. Stripe also publishes source IPs for allowlisting — [Stripe webhooks](https://docs.stripe.com/webhooks)
- Stripe local testing: `stripe listen --forward-to` issues its own signing secret, and `stripe trigger <event>` fires fixtures — [Stripe webhooks](https://docs.stripe.com/webhooks)
- Adyen: "Generate a new HMAC Key" in webhook Security settings, optional Basic auth or OAuth 2.0 to the merchant server, a "Test configuration" button (choose merchant account + event type), and webhook event logs. With no 2xx within 10 seconds, "all webhook events to your endpoint go to the retry queue." Inactive configs are deleted after six months. Test and live HMAC keys differ, and there is no copy function — [Adyen configure webhooks](https://docs.adyen.com/development-resources/webhooks/configure-and-manage/)

### Inferences
- The overlap-window pattern is the same for API keys and webhook secrets: dual-signing during rotation lets receivers rotate without dropping events.
- A good dashboard for this has an endpoint list, then an endpoint detail page with the secret (reveal and roll), the subscribed events, a delivery log with status, response code and next retry, per-event resend, and a send-test-event button.

### Gaps
- Checkout.com, Braintree, Square, Razorpay and Xendit webhook management UIs (secret rotation, resend) were not researched because of tool-call limits.
- Adyen HMAC rotation overlap behavior (whether old and new keys are both valid) was not confirmed.
