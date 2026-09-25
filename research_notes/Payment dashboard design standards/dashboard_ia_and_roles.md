# Merchant Dashboard Information Architecture and Team Roles/Permissions (Stripe, Adyen, Checkout.com, Braintree, Square, Razorpay, Xendit)

Research date: 2026-09-25. All sources fetched live at that date unless noted. The Stripe 2017 blog post is marked as possibly outdated (it is still useful for the stated reasons behind the roles).

## Q1. Top-level navigation, and what a payment detail page shows

### Takeaway
The major PSP dashboards share one layout. There is a Home/overview page, a money area (Balances/Payouts/Finance), a Transactions/Payments list, and customers/products. Developer tooling (API keys, webhooks, request logs) sits in its own area, and Settings holds Team/Security. On the payment detail page the core element is a **chronological timeline of lifecycle events** (authorization, capture, refund, void, dispute). It shows each event's details, including network references such as the ARN, next to risk data (fraud score, 3DS, liability shift) and customer data that is masked by default. The page also offers contextual actions: refund, capture, cancel/void.

### Cited Findings
**Stripe**
- Primary sidebar: **Home** (analytics plus notifications such as unresolved disputes), **Balances** (balance, top-ups, payouts, transaction history), **Transactions** (all payments, fees, transfers, filterable and exportable), **Customers**, **Product catalog**. Below that: a **Shortcuts** section (pinned and recently visited pages) and a **Products** section (Connect; Payments with auth-rate insights, disputes, Radar; Billing; Reporting with Sigma SQL; plus a "More" menu) — [Stripe Web Dashboard](https://docs.stripe.com/dashboard/basics)
- Settings come in three groups, **Personal, Account, Product**. "Team and security" sits under account settings, and PCI compliance details/AOC are also there — [Stripe Web Dashboard](https://docs.stripe.com/dashboard/basics)
- Developer area: **Workbench** shows API and webhook usage, API version upgrades, and API errors filterable by endpoint or type. It "logs every successful or failed request made using your API keys. Each log contains details about the original request, whether it succeeded or failed, the response from Stripe, and a reference to any related API resources." **Sandboxes** give test isolation "without impacting live transactions" — [Stripe Web Dashboard](https://docs.stripe.com/dashboard/basics)
- Keyboard shortcuts are listed by pressing `?`, and global search is available. With Organizations, the Transactions list spans all accounts and can be filtered by account — [Stripe Web Dashboard](https://docs.stripe.com/dashboard/basics)
- The payment detail page has a **Timeline**, and each refund entry offers "View Details". That view shows whether the refund was processed as a reversal and gives the ARN/STAN reference for tracing with the bank. Refunds can also be canceled from the payment details page — [Stripe Refunds](https://docs.stripe.com/refunds)
- Staff can add **notes to a payment** and @mention teammates, who get an email with a link to the payment — [Stripe Start a team](https://docs.stripe.com/get-started/account/teams)

**Adyen (Customer Area)**
- Payments sit under **Payments > Payment list**. It covers "all payments processed under the company account across regions and currencies". Columns: PSP reference ("Adyen's unique 16-character reference"), Merchant reference, Account (merchant account), Date, Amount, Payment method, Status, **Risk score**. CSV export requires the **Export Payments** role — [Adyen Manage payments](https://docs.adyen.com/account/manage-payments)
- Payment details page: "the history of different statuses that the payment has gone through", payment events that include the ARN, "the fraud score assigned to the payment, whether 3D Secure was applied, and whether a liability shift occurred", transaction costs/fees, and shopper details (name, email, phone, IP, address) that are "**masked by default**". Only the **Merchant view PII** role can unmask them — [Adyen Manage payments](https://docs.adyen.com/account/manage-payments)
- The role categories mirror the navigation areas: Account, Developer (API credentials, webhooks, test cards), Finance (payouts, invoices, balances, reports), Financial Products, General, POS, Online Payments, Partners, Platforms, Risk (disputes, fraud), Transactions — [Adyen User roles](https://docs.adyen.com/account/user-roles/)

**Checkout.com**
- Path: **Payments > Processing > All payments**. "By default, each line corresponds to one payment", newest first. List rows show amount/currency, payment method/card, date, and a status whose tooltip explains partial actions and declines — [Checkout.com Payment activity](https://www.checkout.com/docs/business-operations/use-the-dashboard/payment-activity)
- The detail panel holds a full **action timeline (most recent first)**, customer info, action-specific details, and metadata. From there you can capture, void, or refund, and features include fee breakdown, authentication events, MOTO payments, and proof-document generation — [Checkout.com Payment activity](https://www.checkout.com/docs/business-operations/use-the-dashboard/payment-activity)
- The timeline "shows the entire lifecycle, including its path from authorization to capture, void, or refund". Per-event PDFs can be generated, e.g. "Capture PDF" or a "Refund PDF" on a specific partial refund event — [Checkout.com payment proof docs](https://www.checkout.com/docs/business-operations/use-the-dashboard/payment-activity/generate-payment-proof-documents) (via search snippet); [Checkout.com support: find transaction events](https://support.checkout.com/hc/en-us/articles/18327663790482-Find-the-payment-transaction-events-and-details-in-the-Dashboard) (search snippet)

**Braintree**
- The Control Panel is "the user interface for your gateway". Its permission categories mirror its functional areas: Transactions, Customer Management, Reporting, Processing and Security Options, Fraud Tools, User Management, Recurring Billing, Dispute Management, Webhooks, Merchant Accounts, OAuth Applications, Search — [Braintree Role Permissions](https://developer.paypal.com/braintree/articles/control-panel/users-roles/role-permissions)

### Inferences
- Across providers the **timeline is the organising element** of payment detail. Refunds, captures, and disputes are child events on it, not separate pages. Each event carries its own references (ARN/STAN) and documents.
- Developer observability (request logs with request/response, webhook delivery status, API errors) is kept apart from operations views. Stripe puts it in Workbench, Adyen and Braintree put it in a Developer area gated by developer roles. This matches role separation: developer roles can see "events and logs", while support-comms/dispute-only roles cannot (see Q2).
- Masking PII by default and unmasking per role (Adyen) is a pattern worth copying. It lets the default detail view stay useful while limiting sensitive data.

### Gaps
- I did not fetch payment-detail-page documentation for Razorpay, Xendit, Square, or Braintree. Their field-level contents (for example, whether raw acquirer response codes are shown) are unverified.
- None of the sources I read explicitly confirms that raw PSP/acquirer response codes are displayed on the Stripe or Adyen detail page (Checkout.com mentions decline tooltips).
- I found no official engineering or design blog posts explaining *why* the IA is structured this way.

## Q2. Predefined roles, and whether merchants can create custom roles

### Takeaway
Every provider uses **function-named, predefined roles**: owner/admin, developer, finance/analyst, support, disputes, view-only. Custom roles are the enterprise differentiator. Checkout.com and Square (paid tiers) have explicit custom roles, and Stripe has custom roles in Settings → Team → Roles (secondary source). Braintree's position is contested, and Adyen, Razorpay, and Xendit rely on combining fine-grained roles or permissions instead. A common rule is that the most dangerous permissions (user management, SSO, processing settings, ownership) **cannot be put in custom roles**.

### Cited Findings
**Stripe** ([User roles](https://docs.stripe.com/get-started/account/teams/roles))
- Admin roles: **Super Administrator** (the account creator; only a Super Admin can grant Super Admin; manages sandboxes and adds accounts to orgs), **Administrator** ("similar access as the account owner", but "can't delete the default bank account, or change the account owner"), **IAM Administrator** (invite/edit/remove members, user groups, security history; "can't do anything beyond access management" and "can't assign a user to the Administrator or Super Administrator role"), and **Account owner** (the only one who can close the account or transfer ownership).
- **Developer**: "can create secret keys, which grant access to almost all API resources". It can view events/logs and refund payments, but cannot invite team members, edit the payout schedule, or add/edit bank accounts.
- Payment roles: **Analyst** (refund, payouts, exports; cannot edit payout schedule, bank accounts, API keys, or team), **Dispute Analyst** ("can't do anything that's not related to disputes"), **Refund Analyst** (refunds and credit notes only; "can't create payments, view balance, or view connected accounts").
- Support roles: **Support Specialist** (refunds, disputes, products; cannot payout, edit settings, see API keys, or download financial reports), **Support Associate** (the same minus product editing), **Support Communications** (support cases only; "can't access financial information"), **Data Migration Specialist**, **Terminal Specialist**.
- Other roles: **View Only** (views plus exports/reports; no writes), **Accountant**, **Tax Analyst**, **Top-up Specialist**, **Data Engineer**, **Financial Connections Specialist**, plus Connect roles (**Connect Onboarding Analyst**, **Transfer Analyst**, **Connect Risk Analyst**) and Identity roles.
- Each role has an **SSO Role ID** (e.g. `admin`, `iam_admin`, `developer`, `view_only`), which lets IdP groups map to roles.
- Multiple roles are additive: "If you assign a user multiple roles, they're assigned all the permissions of each individual role. Be cautious of conflicts and unintended authority."
- Custom roles: created via Settings → Team → Roles, according to a secondary source ([RapidDev guide](https://www.rapidevelopers.com/stripe-guide/how-to-add-a-new-user-to-a-stripe-account), via search). The official custom-roles URL I tried returned 404, so treat this as unverified.

**Adyen** ([User roles](https://docs.adyen.com/account/user-roles/); [Manage payments](https://docs.adyen.com/account/manage-payments))
- The model is **many fine-grained roles across 13 categories**, bundled into **role groups**: "You can assign roles to users individually, or bundle them into role groups to simplify permission management at scale."
- A new account gets "an **admin** user with the most common roles assigned to it, including the **Merchant admin** role". Merchant admin can "Create and manage users and user roles, Manage account settings…"
- Transaction roles: **Merchant manage payments** ("refund, cancel, or capture a payment"), **Refund payments** (refund only), **Merchant submit batch modifications** (batch refunds/captures/cancels via file upload), **Export Payments**, **Merchant view PII**.
- No custom-role builder is documented. Fine-grained roles plus role groups fill that need.

**Checkout.com** ([User permissions](https://www.checkout.com/docs/business-operations/use-the-dashboard/manage-users/user-permissions); [Manage users](https://www.checkout.com/docs/business-operations/use-the-dashboard/manage-users))
- **14 predefined roles**, including Account owner, Admin, **IAM admin** ("Manages team permission and security settings including single sign-on"), Developer ("Manages workflows and views access keys and payments data"), Compliance operator, Disputes manager/operator, Support manager, Risk manager (decline rules), Read only, and Account application only.
- **Custom roles are supported**, e.g. "Refund Approver", created under Settings → Team settings → Roles and permissions → New role. The following are **excluded from custom roles**: user management (Account owner and Admin only), team security/SSO settings (Account owner and IAM admin only), and processing settings such as website URLs, payment methods, processing channels, and account structure (Account owner and Admin only).
- "A user cannot have multiple roles assigned."
- Roles are **entity-scoped**, e.g. "View list of own sub-entities only" for Admin, Disputes manager, and Support manager.

**Braintree/PayPal**
- The official docs describe roles made of selectable "Rights Granted" (role permissions) across categories. "For security, the **Account Admin** role is required to assign users the Manage Roles and Manage Users permissions." If a user has several roles, "the role with the greatest permissions trumps" — [Braintree Role Permissions](https://developer.paypal.com/braintree/articles/control-panel/users-roles/role-permissions); [Managing Users and Roles](https://developer.paypal.com/braintree/articles/control-panel/users-roles/managing-users-roles)
- **Conflict:** a third-party guide says there are "four fixed roles—Admin, Manager, Support, and Read Only… with no ability to create custom roles" — [Stitchflow](https://www.stitchflow.com/user-management/braintree/manual). The official docs describe creating roles and picking permissions, so prefer the official source.

**Square** ([Permission sets](https://squareup.com/help/us/en/article/5822-employee-permissions); [Advanced Access](https://squareup.com/us/en/staff/advanced-access))
- Preset tiers: Standard, Enhanced, Full. "Full access permissions grant the highest level of access… including sales reports and team member permissions", but managing bank accounts is reserved to the owner.
- Custom permission sets: one on free plans, unlimited on Plus/Premium/Advanced Access. Permissions such as "Issue Refunds" (under Transactions) apply to both POS and Dashboard. Access is **location-scoped**: "a team member assigned to Location A will not see or be able to make changes for Location B."

**Razorpay** ([Manage team](https://razorpay.com/docs/payments/dashboard/account-settings/manage-team/))
- Roles: **Owner**, **Pseudo Owner** (max 2, for "business continuity when the primary owner is unavailable"), **Admin** (like Owner but no team management), **Manager** (no API keys or team), **Operations** (refunds, settlements), **Finance** (views and accepts disputes; **cannot refund or capture**), **View-Only (Auditor)** ("all page views are logged"), **Dispute Manager**, **Support**, **Marketing/Offers Manager**, plus ePos, Finance Manager, Fraud Ops/Analyst, R&D.
- "A team member can be assigned only one role."

**Xendit** ([Users & permissions](https://docs.xendit.co/docs/users-permissions); [Help: user permission](https://help.xendit.co/hc/en-us/articles/360025721291-How-to-Set-User-Permission))
- The model is **permission flags** rather than job roles: View, Edit, Approve (e.g. payout approvals), Admin, Developer (API keys), Withdraw, and No Balance (Indonesia; transactions visible without balance). "A team member can have multiple permissions." The initial account creator has all permissions, and changing them requires contacting Xendit support.

### Inferences
- There are two design families. **Job-role catalogues** (Stripe, Checkout.com, Razorpay) are easy to pick from and give auditors a clear map from job to access. **Composable permissions** (Adyen roles plus groups, Xendit flags, Square/Checkout custom sets) are more flexible. Mature platforms offer a catalogue plus a custom or bundling escape hatch.
- The same separations recur at every provider: **IAM admin vs operational admin** (Stripe, Checkout.com), **refund-only roles** (Stripe Refund Analyst, Adyen Refund payments, Checkout "Refund Approver" example), **finance roles that see money but cannot refund** (Razorpay Finance), **developer roles that get API keys but not bank or team settings**, and **approve vs initiate** for payouts (Xendit Approve vs Edit).
- The single-role (Checkout.com, Razorpay) vs additive multi-role (Stripe, Xendit, Braintree "greatest wins") choice matters. Single-role is simpler to audit, while multi-role risks "unintended authority", as Stripe itself warns.

### Gaps
- The official Stripe custom-roles page could not be fetched (404). Its availability tier and granularity are unverified.
- The full permission matrix for Checkout.com's 14 roles and for Razorpay's specialised roles was not captured.

## Q3. Invites, multi-account/organization access, and account switching

### Takeaway
Invites are email-based, role-assigned at invite time, and expire (Stripe: 10 days). Only admins or IAM admins can invite. Multi-entity businesses get an **organization layer** above accounts (Stripe Organizations, Checkout.com entities/sub-entities, Adyen company vs merchant accounts, Square locations, Xendit sub-accounts). That layer provides consolidated lists, org-level roles, and centralised SSO, and one login can reach several accounts.

### Cited Findings
- Stripe invite flow: Team → Add member, enter one or more emails, select roles ("Grant the lowest permission required by the user to perform their job"), review, then Send invites. "Invites to your Stripe account expire after 10 days." Roles can be edited afterwards. Stripe logs team account activity for 180 days under **Security history** — [Stripe Start a team](https://docs.stripe.com/get-started/account/teams)
- Stripe Organizations: "centralized view… of all of your business lines or subsidiaries". It gives consolidated transactions, disputes, and customers, unified reports across currencies, "Streamline team management and SSO from a centralized location", org-wide Sigma, account groups, and global search across "all of the accounts they have access to". Use cases include per-country accounts for local acquiring and separate business units "to isolate operations and finances" — [Stripe Organizations](https://docs.stripe.com/get-started/account/orgs)
- Adding an account to an org requires being a Super Administrator in both the account and the organization — [Stripe User roles](https://docs.stripe.com/get-started/account/teams/roles)
- In a Stripe org, customers can be created or exported only at the account level. The org-level view links through to the owning account — [Stripe Web Dashboard](https://docs.stripe.com/dashboard/basics)
- Adyen: the payment list covers all payments "under the company account across regions and currencies", with an Account (merchant account) column. Roles are assigned mainly at merchant-account level — [Adyen Manage payments](https://docs.adyen.com/account/manage-payments); [Adyen User roles](https://docs.adyen.com/account/user-roles/)
- Checkout.com: roles are entity-scoped ("own sub-entities only"), and the Account owner can "manage account structure" — [Checkout.com User permissions](https://www.checkout.com/docs/business-operations/use-the-dashboard/manage-users/user-permissions)
- Braintree: only Admin-role users can invite, under Settings > Users. SCIM provisioning is supported — [Stitchflow](https://www.stitchflow.com/user-management/braintree/manual); [Braintree SCIM FAQ](https://developer.paypal.com/braintree/articles/control-panel/users-roles/scim/scim-faq)
- Xendit: Settings > Team Members > +Add Member, pick permissions, send the invite. The invitee sets a password. "The same email address can be used for multiple Xendit dashboards". xenPlatform sub-accounts have their own team invites — [Xendit Users & permissions](https://docs.xendit.co/docs/users-permissions); [Xendit invite for sub-accounts](https://help.xendit.co/hc/en-us/articles/8253904898841-How-to-Invite-Team-Members-into-xenPlatform-Sub-Account-Dashboard)
- Square: access is location-scoped, and changes to a permission set apply to everyone assigned to it — [Square Permission sets](https://squareup.com/help/us/en/article/5822-employee-permissions)

### Inferences
- The identity model is: one user identity with **membership per account** (role per account), plus an optional org layer. The account switcher and "org view" are the UI expression of that model. Consolidated views are read-heavy, while writes stay at the account level (Stripe customers).

### Gaps
- I did not verify account-switcher UI details (placement, per-account role display) for any provider.
- Razorpay's multi-account/MID switching was not researched.

## Q4. Why roles are split this way (least privilege, separation of duties, PCI DSS Req 7)

### Takeaway
Providers justify role splits by **job function plus least privilege**, and PCI DSS v4.0 Requirement 7 states the same principle almost word for word. Explicit security reasoning in provider docs focuses on three things: roles that can invite users (account-takeover amplification), unmasking PII (PCI scope), and fund movement (2FA gating).

### Cited Findings
- PCI DSS v4.0 **7.2.1**: an access control model granting access "based on users' job classification and functions" and "the least privileges required (for example, user, administrator) to perform a job function". **7.2.2**: access for users "including privileged users" assigned by job classification and least privilege. **7.2.3**: "Required privileges are approved by authorized personnel." **7.2.4**: review all user accounts and privileges "at least once every six months", with management acknowledgement. **7.2.5**: application/system accounts limited to least privilege. **7.2.6**: query access to stored CHD only via applications and roles, and direct repository access only for responsible admins. **7.3.3**: access control set to "deny all" by default — [Microsoft Learn: PCI-DSS Requirement 7 (quotes requirement text)](https://learn.microsoft.com/en-us/entra/standards/pci-requirement-7)
- Stripe (2017, possibly outdated but still reflected in current roles): "Different job functions need a more distinct set of permissions when accessing Stripe accounts." For support: "We limit what aggregate financial data they can access, such as gross volume or payouts." Goal: "help ensure that sensitive information and actions are protected" — [Stripe blog, Apr 2017](https://stripe.com/blog/new-roles-and-permissions-in-the-dashboard)
- Stripe's current guidance: "Grant the lowest permission required by the user to perform their job" — [Stripe Start a team](https://docs.stripe.com/get-started/account/teams)
- Stripe warns about invite-capable roles: "These roles can invite users to your account. If an attacker compromises a user with one, they can invite additional users under their control." — [Stripe User roles](https://docs.stripe.com/get-started/account/teams/roles)
- Stripe gates fund movement on 2FA: "Your account must require two-step authentication in order to allow non-Administrators with this role [Transfer Analyst] to transfer funds." — [Stripe User roles](https://docs.stripe.com/get-started/account/teams/roles)
- Stripe keeps the IAM Administrator out of payments, balances, and API keys, and it cannot grant Admin/Super Admin. This separates access administration from business operations — [Stripe User roles](https://docs.stripe.com/get-started/account/teams/roles)
- Adyen: viewing unmasked PII "can affect your PCI DSS compliance level", so it has its own role (Merchant view PII) — [Adyen User roles](https://docs.adyen.com/account/user-roles/)
- Checkout.com keeps user management, SSO, and processing settings out of custom roles, restricting them to Account owner/Admin/IAM admin — [Checkout.com User permissions](https://www.checkout.com/docs/business-operations/use-the-dashboard/manage-users/user-permissions)
- Braintree: "For security, the Account Admin role is required to assign users the Manage Roles and Manage Users permissions." — [Braintree Role Permissions](https://developer.paypal.com/braintree/articles/control-panel/users-roles/role-permissions)
- Razorpay: Pseudo Owner exists for continuity. The View-Only Auditor role logs every page view — [Razorpay Manage team](https://razorpay.com/docs/payments/dashboard/account-settings/manage-team/)
- Square recommends giving owner-level access only to "your most trusted individuals". Bank account management is withheld even from Full access — [Square Permission sets](https://squareup.com/help/us/en/article/5822-employee-permissions)
- Stripe's Security history (180 days of team activity) and Adyen's timeline support auditability — [Stripe Start a team](https://docs.stripe.com/get-started/account/teams)

### Inferences
- The splits follow the four questions PCI and auditors ask: who can **grant access** (IAM admin), who can **move money out** (payouts, bank accounts, transfers: the most restricted, often 2FA-gated), who can **reverse money to customers** (refunds: delegated to support, but in isolatable roles), and who can **see sensitive data** (PII unmasking, API secret keys).
- Separation of duties appears explicitly as approve vs initiate (Xendit Approve permission; Checkout.com "Refund Approver" custom-role example). The main vendors' docs did not frame it as a named "maker-checker" requirement.
- Support load and developer experience are implied rather than stated. Support roles can refund and resolve disputes without calling admins, and developer roles get keys and logs without bank or team powers.

### Gaps
- None of the vendor docs I read cites PCI DSS Requirement 7 by number. The link to PCI comes from Adyen's PII remark plus the PCI text itself.
- I found no vendor statement about 6-monthly access reviews (7.2.4) or built-in access-review tooling.

## Q5. UI patterns for dangerous actions (refunds, amount entry, idempotency)

### Takeaway
Refund, capture, and void are **contextual actions on the payment** (overflow menu or detail page) inside a modal. The modal **defaults to the full amount**, lets you enter a partial amount, requires a **reason** (plus a note if "Other") and an explicit confirm step, and caps the total at the original amount. The API uses **minor units** (integers), while the Dashboard modal is presented in currency amounts. Reversible states (uncaptured) are steered toward cancel/void instead of refund.

### Cited Findings
- Stripe refund flow: overflow menu (⋯) → **Refund payment**. "By default, you'll issue a full refund. For a partial refund, enter a different refund amount." "Select a reason for the refund. If you select **Other**, you must add a note that explains the reason". "You can't refund a total greater than the original charge amount." Bulk refunds are full-only: "partial refunds must be issued individually" — [Stripe Refunds](https://docs.stripe.com/refunds)
- Stripe cancel refund: choose the specific partial refund from a dropdown, then an explicit confirm button "**Yes, cancel refund**". Cancel payment likewise requires a reason, with a note if Other, then "Yes" — [Stripe Refunds](https://docs.stripe.com/refunds)
- Stripe API amounts: "provide an `amount` parameter as an integer in cents (or the charge currency's smallest currency unit)" — [Stripe Refunds](https://docs.stripe.com/refunds)
- Stripe recommends manual auth/capture to cancel or reduce the capture instead of refunding, which lowers refund costs. It also warns about double refunds on bank debits when a dispute is also in flight, and the `charge_for_pending_refund_disputed` failure reason exists — [Stripe Refunds](https://docs.stripe.com/refunds)
- Adyen: refund requires the Merchant manage payments or Refund payments role. The user specifies an amount and reference, then confirms, and refunds are "only available if the payment has been captured". Capture is available only when status is Authorised. **Cancel requires a confirmation code**, a typed-confirmation friction pattern — [Adyen Manage payments](https://docs.adyen.com/account/manage-payments)
- Checkout.com: select a payment, choose capture/void/refund, optionally enter a partial amount, confirm, then refresh the status. Partial amounts appear in status tooltips — [Checkout.com Payment activity](https://www.checkout.com/docs/business-operations/use-the-dashboard/payment-activity)
- Square: refunds are gated by an "Issue Refunds" permission that applies to both POS and Dashboard. Community threads ask for velocity or amount limits on employee refunds, which suggests such limits are not native — [Square Refunds](https://squareup.com/help/us/en/article/6116-process-refunds); [Square Community thread](https://community.squareup.com/t5/Staff-Payroll/Limiting-Refund-Abuse-by-employees-with-refund-permission-max/m-p/727994) (community forum, low authority)

### Inferences
- A safe refund modal typically has: full amount prefilled, a remaining-refundable cap, a required reason code, a free-text note when needed, a named confirm button, and an action that is available only in valid states (captured → refund, authorised → capture/void).
- Stronger friction (a typed confirmation code) is used for actions that cannot be undone, like Adyen cancel. Batch actions are limited to the safest variant (Stripe bulk refunds are full-only).

### Gaps
- None of the sources explains how dashboards prevent **double-submit or duplicate refunds** from the UI, for example whether the Dashboard sends idempotency keys. I did not fetch Stripe's idempotency docs, so no claim is made.
- I did not confirm whether Dashboard amount fields take major units with a currency-aware decimal mask, or minor units. The docs only confirm minor units for the API.
- Maker-checker (dual approval) for refunds is not documented as native at Stripe or Adyen. Checkout.com's "Refund Approver" is only a naming example.
