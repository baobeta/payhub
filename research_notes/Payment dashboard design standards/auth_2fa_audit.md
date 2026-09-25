# Dashboard authentication, 2FA, sessions and audit/security history: market practice and compliance drivers

Research date: 2026-09-25. Budget: about 18 tool calls. Items marked **[background knowledge, not fetched]** come from the researcher's prior knowledge of the standards and were not checked against a source in this session. The report writer should treat them as lower confidence.

---

## 1. Is 2FA mandatory for dashboard users? Which methods? Can admins enforce it org-wide?

### Takeaway
Most providers now either make 2FA mandatory (Adyen, Braintree, Xendit, and Checkout.com once enrolled) or let an admin enforce it for the whole team (Stripe, Square, Razorpay). TOTP authenticator apps are supported everywhere. SMS is still common but is now labelled weakest. Passkeys and WebAuthn security keys are offered by the leaders (Stripe, Checkout.com). Where SSO is used, it replaces the provider's own MFA.

### Cited Findings
- **Stripe** supports passkeys, hardware security keys, TOTP and SMS. Stripe recommends passkeys or hardware keys "because they're resistant to phishing". It says SMS "is vulnerable to SIM-swapping and interception, so use it only as a last resort". — [Stripe: Security at Stripe](https://docs.stripe.com/security)
- **Stripe** ranks its methods from strongest to weakest: passkeys, security keys, Touch ID/Windows Hello (needs another method enrolled first), authenticator app, SMS. A backup code is issued at enrollment. 2FA is **not mandatory by default**, but team admins can require it for all team members from Team settings. Stripe advises enabling two or more methods. — [Stripe Support: enable two-step authentication](https://support.stripe.com/questions/enable-two-step-authentication)
- **Adyen** requires every Customer Area user to set up MFA or SSO: "All users with an Adyen Customer Area account must set up Multifactor Authentication (MFA) or Single Sign-On". The methods are an authenticator app (TOTP: Google Authenticator, Okta Verify, Microsoft Authenticator) or SMS OTP, and SMS works only in live environments. Each user can register up to two devices, one method per device. Admins can view users and remove their registered devices under Settings > Users. — [Adyen Docs: Multifactor authentication](https://docs.adyen.com/account/multifactor-authentication); [Adyen Help](https://help.adyen.com/en_US/knowledge/account/access-your-customer-area/what-is-multifactor-authentication-mfa-and-how-can-i-add-it-to-my-account)
- **Checkout.com** offers an authenticator app, or a "security key or biometric authenticator" (WebAuthn/FIDO). If both are set up, the security key takes priority. Once a user enrolls, they "must always have a valid MFA method to log in". Account owners and IAM admins can reset a locked-out user's MFA, and the user must then re-enroll. Shared or group accounts are not supported. "If your organization leverages single sign-on (SSO), MFA will not be available within the Dashboard." — [Checkout.com Docs: Configure MFA](https://www.checkout.com/docs/business-operations/use-the-dashboard/configure-multi-factor-authentication)
- **Braintree (PayPal)** has required 2FA for all Control Panel users since September 2023. Users without it see a setup assistant after logging in. Codes come from an authenticator app or SMS. Only users with the Account Admin role can disable 2FA for other users. — [Braintree: Two-Factor Authentication](https://developer.paypal.com/braintree/articles/risk-and-security/control-panel-security/two-factor-authentication)
- **Square** lets sellers with Account & Settings permission choose between "Require team members to use 2-Step Verification" and "Allow team members to skip". Team members who have not enabled it are forced to set it up at their next sign-in, and new team members are prompted to set it up when they are created. — [Square Support: Set up two-step verification](https://squareup.com/help/us/en/article/5593-2-step-verification)
- **Razorpay** lets the account owner switch on "Two-Factor Authentication for the team", which makes 2FA mandatory for all team members. The OTP goes to the registered mobile number, so it appears to be SMS. Users are locked out after entering a wrong OTP 9 times. Owners can reset 2FA for locked users, but an owner who is locked out must contact support. Assigning the Pseudo Owner role requires extra OTP/2FA. — [Razorpay Docs: Manage Team](https://razorpay.com/docs/payments/dashboard/my-account/manage-team/); [RazorpayX 2FA](https://razorpay.com/docs/x/manage-teams/2fa/)
- **Xendit** says "Enabling 2FA is mandatory". It supports SMS and TOTP apps (Google Authenticator, Authy, Microsoft Authenticator), and recovery codes are issued. — [Xendit Docs: Set up 2FA](https://docs.xendit.co/dashboard/2-factor-authentication/)

### Inferences
- The baseline expectation is mandatory 2FA, or an admin setting that forces it, with TOTP plus recovery codes. Leading providers add passkeys and WebAuthn and actively discourage SMS.
- The lockout thresholds seen (Razorpay: 9 wrong OTPs) fit within PCI DSS 8.3.4's "10 or fewer attempts".
- Checkout.com and Adyen both treat SSO as a replacement for their own MFA and hand MFA to the customer's identity provider.

### Gaps
- No primary source found on whether Adyen, Braintree, Square or Razorpay support passkeys or WebAuthn.
- No primary source found on how Stripe's "require 2FA" setting treats SSO-only users.
- Square's supported methods (SMS vs. app) and backup codes were not confirmed from the page snippet.

---

## 2. SSO (SAML/OIDC) and SCIM availability, and at which tier

### Takeaway
SAML 2.0 SSO is standard across the enterprise-oriented providers (Stripe, Checkout.com, Adyen). Stripe has the most complete documented offering: SAML with mandatory or optional SSO, JIT provisioning, SCIM, and role mapping from the IdP. No provider documented OIDC for dashboard SSO, and none tied SSO to a pricing tier in the sources found.

### Cited Findings
- **Stripe** supports SAML 2.0 with any IdP, with guides for Okta, Entra ID, Google Workspace and OneLogin. Admins can mandate SSO for all users or allow SSO alongside email and password. Stripe also supports JIT account creation, assigning roles through the IdP, IdP- and SP-initiated sign-in, and SCIM. Without SCIM, Stripe is not told immediately when a user loses access in the IdP; access is revoked at the next SSO sign-in after their session expires. — [Stripe Docs: SSO](https://docs.stripe.com/get-started/account/sso)
- With SSO plus SCIM, Stripe says customers "can enforce authentication policies centrally through your identity provider". — [Stripe: Security](https://docs.stripe.com/security)
- **Checkout.com** supports any IdP that supports SAML 2.0, with both IdP- and SP-initiated sign-in and a dedicated Google flow. — [Checkout.com Docs: Single sign-on](https://www.checkout.com/docs/business-operations/use-the-dashboard/single-sign-on)
- **Adyen** offers SSO as the alternative to MFA. — [Adyen Docs: MFA](https://docs.adyen.com/account/multifactor-authentication)
- **Braintree** appears in the third-party OneLogin connector catalogue. — [OneLogin: Braintree connector](https://www.onelogin.com/connector/braintree)

### Inferences
- SAML-first, with SCIM for deprovisioning, is the market norm. SCIM matters for compliance because it closes the gap between offboarding someone in the IdP and removing their dashboard access. That gap is relevant to PCI DSS 8.2.5 (revoke access for terminated users immediately) **[background knowledge, not fetched]** and SOC 2 CC6.2/CC6.3.

### Gaps
- Pricing tier for SSO was not found for any provider.
- SSO and SCIM for Square, Razorpay and Xendit were not found. Braintree's native SSO documentation was not found.

---

## 3. Session policies: idle timeout, re-authentication for sensitive actions, IP allowlists

### Takeaway
Public documentation on dashboard session length is thin. Stripe is the only provider found documenting "sensitive action authentication" (step-up MFA) plus notifications for logins from new devices or IPs. IP allowlists are documented for API keys (Stripe access policies) rather than for dashboard logins.

### Cited Findings
- **Stripe** places MFA under a heading called "Sensitive action authentication". Stripe watches logins for usual devices, consistent IPs and failed attempts, and emails users automatically about logins from unknown IPs or devices. — [Stripe: Security](https://docs.stripe.com/security)
- **Stripe** lets customers "configure access policies for API keys to prevent use from unauthorized locations". This is IP restriction on API keys, not on dashboard sessions. — [Stripe: Security](https://docs.stripe.com/security)
- **Stripe** logs an `api_key_viewed` event when an API key's secret is viewed, which means secret reveal is treated as a discrete audited action. — [Stripe Docs: Activity logs](https://docs.stripe.com/activity-logs)
- **Razorpay** requires extra OTP/2FA when assigning the Pseudo Owner role, which is a step-up check on a privilege change. — [Razorpay Docs: Manage Team](https://razorpay.com/docs/payments/dashboard/my-account/manage-team/)
- **Adyen, Checkout.com and Xendit** MFA docs do not address session timeout. — [Adyen](https://docs.adyen.com/account/multifactor-authentication); [Checkout.com](https://www.checkout.com/docs/business-operations/use-the-dashboard/configure-multi-factor-authentication); [Xendit](https://docs.xendit.co/dashboard/2-factor-authentication/)
- **PCI DSS 8.2.8**: "If a user session has been idle for more than 15 minutes, the user is required to re-authenticate to re-activate the terminal or session." Assessors check that idle timeouts are "15 minutes or less". It applies to interactive user sessions in the CDE. — [PCI Compliance Hub: 8.2.8](https://pcicompliancehub.com/blog/pci-dss-requirement-8-2-8-idle-timeout-reauthentication); [Twosense: PCI 4.0 15-minute timeouts](https://www.twosense.ai/blog/pci-4.0-required-15-minute-timeouts)

### Inferences
- The common design pattern is step-up re-authentication (re-enter MFA or password) before sensitive actions: revealing a live secret key, changing the payout bank account, inviting a user or raising their role, and turning off 2FA. Stripe's heading suggests it does this, but no primary source listed the exact actions that trigger it.
- A 15-minute idle timeout is only strictly required where the dashboard session is inside the CDE, for example if it can display full PANs. A merchant dashboard that only shows masked or tokenized card data is usually outside the merchant's CDE. Many providers still choose short idle timeouts to be defensible under SOC 2 CC6.1. OWASP ASVS V3 also recommends idle and absolute session timeouts, with 15 to 30 minutes typical for high-value applications **[background knowledge, not fetched]**.

### Gaps
- No primary source gave the actual dashboard idle or absolute timeout for any provider.
- No provider documented IP allowlisting for dashboard login. It may exist in enterprise plans, but this is unconfirmed.
- No explicit list of step-up-protected actions was found for any provider. The payout-bank-change step-up is common in practice but was not documented in the sources found.

---

## 4. Audit and security history: events logged, who can see them, retention, export

### Takeaway
Stripe is the benchmark. It has a Dashboard "Security history" with 180 days of team-member activity, which can be exported, and since April 2026 an Activity Logs API (preview) for SIEM ingestion that keeps 6 months of logs. Adyen offers audit logs for specific features (terminals, platform capabilities) rather than one global log. Razorpay logs page views for its auditor role. No public documentation was found for Checkout.com, Braintree, Square or Xendit.

### Cited Findings
- **Stripe Security history**: "Stripe logs the account activity of team members during the past 180 days", shown at Settings > Security history. — [Stripe Docs: Start a team](https://docs.stripe.com/get-started/account/teams)
- **Stripe Security history contents**: "records of sensitive account activity, such as logging in or changing bank account information". Login monitoring covers device, IP and failed attempts, and "Users can export historical information from the logs". — [Stripe: Security](https://docs.stripe.com/security)
- **Stripe Activity Logs API** (version `2026-07-29.preview`) gives programmatic access to security history and is intended for "SIEM" integration and "compliance frameworks such as SOC 2 or PCI DSS". It tracks the following events (available since April 1, 2026):
  - API keys: `api_key_created`, `api_key_deleted`, `api_key_updated`, `api_key_viewed`. A key rotation shows up as delete plus create.
  - Invitations: `user_invite_created`, `user_invite_deleted`, `user_invite_accepted`.
  - Roles: `user_roles_updated`, `user_roles_deleted`, with `details.user_roles.source` showing whether the change came from the Dashboard, SCIM or SSO. SCIM and SSO coverage has been available since August 12, 2026.

  Each entry has actor, timestamp, affected resources and metadata. **Retention is 6 months.** Events appear about 10 minutes after they happen. Access requires a secret key with the "Activity logs: Read" permission. — [Stripe Docs: Activity logs](https://docs.stripe.com/activity-logs)
- **Stripe Team export**: the Team member table can be exported as CSV. A third-party source reports that the Team UI does not show last login. — [Stitchflow: Stripe user management](https://www.stitchflow.com/user-management/stripe/manual) (third party)
- **Adyen**: the Customer Area has an Audit Log page showing terminal-related events (who, what changed, when). A separate audit log on the account holder page records "human user actions to request, enable, or disable a capability", which affects onboarding and payouts. — [Adyen: Track terminal changes with Audit Logs](https://www.adyen.com/the-latest/track-terminal-changes-with-audit-logs); [Adyen: capability audit log for platforms](https://www.adyen.com/the-latest/view-capability-status-changes-with-the-new-audit-log-for-platforms)
- **Razorpay**: for the View-Only (Auditor) role, "All page views are logged for audit and compliance purposes". Pseudo Owner actions "are logged with 'Pseudo Owner' designation". — [Razorpay Docs: Manage Team](https://razorpay.com/docs/payments/dashboard/my-account/manage-team/)
- **Checkout.com, Braintree, Square, Xendit**: no dashboard audit-log documentation was found in the pages searched (see the search results above).

### Inferences
- The market-standard set of events to log: sign-in success and failure (with IP and device), MFA enroll, remove and reset, password change, user invite, removal and role change, API key create, reveal, roll and delete, webhook endpoint changes, payout bank account changes, and payout and refund actions. These line up with PCI DSS 10.2.1.2 (admin actions), 10.2.1.4 (invalid access attempts) and 10.2.1.5 (changes to authentication credentials).
- Stripe keeps 180 days in the UI and 6 months in the API, which is below PCI DSS 10.5.1's 12 months. This works because PCI 10.5.1 applies to CDE system logs held by the entity, not to a merchant-facing feature. Merchants who need 12 months are expected to export to their own SIEM, which is why the API exists. A product that offers 12 months or more of history, or continuous export, would be above the market baseline.

### Gaps
- Who can view Stripe Security history (which roles) was not confirmed.
- The export format for Stripe's UI log (for example CSV) was not confirmed.
- No public documentation was found for Checkout.com, Braintree, Square or Xendit audit logs. They may exist behind login.

---

## 5. What PCI DSS v4.0 Req 8 and Req 10 (plus SOC 2, ISO 27001, PSD2) require, and how that maps to UI features

### Takeaway
PCI DSS v4.0/4.0.1 Req 8 sets the numbers dashboards copy: MFA for all non-console CDE access (8.4.2, mandatory since 31 March 2025), a 15-minute idle timeout (8.2.8), and lockout after 10 or fewer attempts for at least 30 minutes (8.3.4). Req 10 sets audit content (10.2.x), tamper protection (10.3.x), daily automated review (10.4.1.1) and 12-month retention with 3 months immediately available (10.5.1). SOC 2 CC6/CC7 and ISO 27001 require the same controls at a principle level, without fixed numbers.

### Cited Findings: PCI DSS Req 8
- **8.2.8**: idle more than 15 minutes means re-authentication is required. — [PCI Compliance Hub](https://pcicompliancehub.com/blog/pci-dss-requirement-8-2-8-idle-timeout-reauthentication)
- **8.3.4**: lock out the user ID after no more than 10 invalid attempts, for at least 30 minutes or until identity is confirmed. — [Linford & Co / search summary](https://linfordco.com/blog/pci-dss-4-0-requirements-guide/); [PCI Compliance Hub](https://pcicompliancehub.com/blog/pci-dss-requirement-8-2-8-idle-timeout-reauthentication)
- **8.4.2**: MFA for all non-console access into the CDE, not just remote access. This is a new v4.0 requirement that was future-dated to 31 March 2025. — [PCI SSC: Summary of Changes v3.2.1 to v4.0](https://listings.pcisecuritystandards.org/documents/PCI-DSS-v3-2-1-to-v4-0-Summary-of-Changes-r1.pdf); [SecurityMetrics: new requirements in 4.0.1](https://www.securitymetrics.com/blog/a-guide-to-new-requirements-in-pci-dss-4-0-1)
- **[background knowledge, not fetched]**:
  - 8.4.1: MFA for non-console administrative access into the CDE.
  - 8.4.3: MFA for all remote network access.
  - 8.5.1: MFA systems must not be open to replay, must not be bypassable (unless a documented exception is authorized), must use at least two different factor types, and require all factors to succeed.
  - 8.2.1: unique IDs.
  - 8.2.2: shared/generic accounts only by exception.
  - 8.2.5: terminated users revoked immediately.
  - 8.2.6: inactive accounts removed or disabled within 90 days.
  - 8.3.6: passwords at least 12 characters (8 if the system cannot support 12), with letters and numbers.
  - 8.3.9: change passwords every 90 days if the password is the only factor.
  - 8.6.x: system and application accounts.

### Cited Findings: PCI DSS Req 10
- **10.1–10.7 structure**:
  - 10.2: "Audit logs are implemented to support the detection of anomalies and suspicious activity, and the forensic analysis of events."
  - 10.3: "Audit logs are protected from destruction and unauthorized modifications."
  - 10.4: logs reviewed.
  - 10.5: "Audit log history is retained and available for analysis."
  - 10.6: time synchronization.
  - 10.7: failures of critical security controls are detected.

  — [NXLog: PCI DSS 4.0 logging](https://nxlog.co/news-and-blog/posts/pci-dss-log-collection-compliance)
- **10.2.1.1–10.2.1.7**: logs must capture:
  - all individual user access to cardholder data
  - all actions by anyone with administrative access
  - all access to audit logs
  - all invalid logical access attempts
  - all changes to identification and authentication credentials (creating accounts, raising privileges, changes to admin accounts)
  - initialization, stopping or pausing of audit logs
  - creation and deletion of system-level objects

  — [RSI Security: PCI Requirement 10](https://blog.rsisecurity.com/tracking-and-monitoring-under-pci-dss-requirement-10/)
- **Log entry fields**: user ID, event type, date and time, success or failure, origin, and identity of the affected data or resource. RSI Security labels this "10.3.1–10.3.7", but in v4.0 it is **10.2.2**. RSI appears to use the old v3.2.1 numbering (10.3.x), so the numbering conflicts. — [RSI Security](https://blog.rsisecurity.com/tracking-and-monitoring-under-pci-dss-requirement-10/)
- **10.4.1 / 10.4.1.1**: security-event logs reviewed at least daily, using automated mechanisms (10.4.1.1 is new in v4.0). **10.4.2/10.4.2.1**: other logs reviewed at a frequency set by targeted risk analysis. — [RSI Security](https://blog.rsisecurity.com/tracking-and-monitoring-under-pci-dss-requirement-10/)
- **10.5.1**: keep audit log history for at least 12 months, with at least the most recent 3 months immediately available for analysis. — [KirkpatrickPrice: 10.5.1](https://explore.kirkpatrickprice.com/videos/pci-v4-0-10-5-1-retain-audit-log-history-for-at-least-12-months)
- **[background knowledge, not fetched]**:
  - 10.3.1: read access to logs limited to those with a job need.
  - 10.3.2: logs protected from modification.
  - 10.3.3: logs promptly backed up to a central, hard-to-alter server.
  - 10.3.4: file-integrity monitoring or change detection on logs.
  - 10.6.1–10.6.3: time sync (NTP) and protection of time data.

### Cited Findings: SOC 2 / ISO / PSD2
- **SOC 2 CC6.1**: restrict logical access; identify and authenticate users before access; this includes multi-factor procedures. **CC6.2**: access approved before it is granted. **CC6.3**: role-based access and periodic access reviews. **CC7.2**: monitor for anomalies and security events. — [ISMS.online: CC6.1](https://www.isms.online/soc-2/controls/logical-and-physical-access-controls-cc6-1-explained/); [Compass IT: CC series](https://www.compassitc.com/blog/soc-2-common-criteria-list-cc-series-explained); [Bytebase: CC6/CC7](https://www.bytebase.com/blog/database-access-control-for-soc2/)
- Stripe positions its Activity Logs export for "SOC 2 or PCI DSS" audit reporting. It holds PCI Service Provider Level 1 and publishes SOC 1 and SOC 2 Type II reports annually, plus a public SOC 3. — [Stripe Docs: Activity logs](https://docs.stripe.com/activity-logs); [Stripe: Security](https://docs.stripe.com/security)
- **ISO/IEC 27001:2022 Annex A [background knowledge, not fetched]**:
  - 5.15: access control
  - 5.16: identity management
  - 5.17: authentication information
  - 5.18: access rights, including reviews
  - 8.2: privileged access rights
  - 8.5: secure authentication (MFA and session controls)
  - 8.15: logging
  - 8.16: monitoring activities
  - 8.17: clock synchronization

  These state no fixed numbers. Organizations set their own values based on risk.
- **PSD2 [background knowledge, not fetched]**: Strong Customer Authentication under RTS 2018/389 applies to payers (Art. 97), not to merchant dashboard staff. The RTS does set some reference values:
  - Art. 4(3)(d): maximum of 5 failed SCA attempts before a block.
  - Art. 4(3)(e): 5-minute inactivity timeout for online payment-account sessions.
  - Art. 4(2): dynamic linking.

  These values sometimes influence EU providers' dashboard design, but they are not a legal requirement for merchant consoles.

### Mapping table (for the report writer)
| UI feature | Market examples | Primary driver |
|---|---|---|
| Mandatory 2FA / admin-enforced 2FA | Adyen, Braintree, Xendit (mandatory); Stripe, Square, Razorpay (admin toggle); Checkout.com (mandatory once enrolled) | PCI 8.4.1/8.4.2, 8.5.1; SOC 2 CC6.1; ISO 8.5 |
| Passkeys / WebAuthn, SMS discouraged | Stripe, Checkout.com | PCI 8.5.1 (resists replay); phishing resistance |
| Recovery codes; admin MFA reset | Stripe, Xendit, Checkout.com, Razorpay | Availability; PCI 8.3.x identity confirmation before reset |
| SAML SSO + SCIM + JIT | Stripe (full), Checkout.com, Adyen | PCI 8.2.5 (prompt deprovisioning); SOC 2 CC6.2/6.3 |
| Lockout after N failures | Razorpay (9 OTP failures) | PCI 8.3.4 (≤10, ≥30 min) |
| Idle timeout / re-auth | Not publicly documented | PCI 8.2.8 (15 min, if in CDE); OWASP ASVS V3 |
| Step-up re-auth for sensitive actions; new-device login email | Stripe ("sensitive action authentication", unknown-IP/device email), Razorpay (Pseudo Owner OTP) | PCI 10.2.1.2/10.2.1.5 (these are the audited high-risk events); SOC 2 CC6.1/CC7.2 |
| Security history UI + export | Stripe (180 days UI, export); Adyen (terminal and capability logs) | PCI 10.2.x; SOC 2 CC7.2 |
| Audit log API / SIEM feed | Stripe Activity Logs API (6 months, preview 2026) | PCI 10.4.1.1 (automated review), 10.5.1 (customer-side 12-month retention) |
| Unique users, no shared logins | Checkout.com explicitly | PCI 8.2.1/8.2.2 |
| Least-privilege roles, auditor role | Stripe roles; Razorpay 16+ roles incl. View-Only Auditor | PCI 7.2; SOC 2 CC6.3 |

### Inferences
- A merchant dashboard is typically *out of* the merchant's CDE when card data is tokenized. PCI Req 8/10 numbers therefore bind the provider's own internal staff access, and the merchant-facing features are "defense in depth" plus SOC 2 evidence. If a dashboard displays full PANs or allows manual card entry (virtual terminal), the session is in CDE scope and the 8.2.8 (15 min), 8.3.4 and 8.4.2 numbers apply directly.
- For a new product aiming at the market standard:
  - Mandatory TOTP or passkey 2FA with recovery codes; SMS only as a fallback.
  - An org-level "require 2FA" setting.
  - Lockout at 10 or fewer failures for 30 minutes or more.
  - A 15-minute idle timeout.
  - Step-up MFA for secret-key reveal, payout-account change, member invite or role change, and disabling 2FA.
  - An immutable, append-only security history with PCI 10.2.2 fields, exportable, kept 12 months or more (above Stripe's 6 months).

### Gaps
- The official PCI SSC v4.0.1 PDF was not fetched directly. Requirement wording comes from reputable secondary summaries plus the PCI SSC Summary of Changes listing.
- The 10.2.2 vs. 10.3.x numbering conflict in the RSI source needs a check against the primary document.
- AICPA TSC primary text was not fetched.
- OWASP ASVS and the Session Management Cheat Sheet were not fetched in this session. The values attributed to them are background knowledge.
