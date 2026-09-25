# Operating RBAC in production: exposing permissions, testing, auditing, and preventing broken access control

## 1. How should permissions reach a SPA frontend, and why must the server still enforce them?

### Takeaway
Common patterns: (a) the server sends the user's rule set once, for example CASL rules packed into a `/me` response or a JWT; (b) each resource in an API response carries its own "can" flags, as in GitHub's `permissions` object on repositories. Either way the frontend copy only controls what the UI shows. OWASP ASVS 5.0 (8.3.1) requires every check to run again in a trusted server layer.

### Cited Findings
- GitHub repository responses include a `permissions` object with five booleans (`admin`, `maintain`, `push`, `triage`, `pull`). Each one says what the *authenticated user* can do on that repo. The object appears on endpoints such as `GET /user/repos` and on single-repo reads. — [GitHub REST docs: Repositories](https://docs.github.com/en/rest/repos/repos#get-a-repository)
- CASL (`@casl/ability/extra`) has `packRules`/`unpackRules`. The backend builds the user's ability, packs its rules and sends them to the frontend, sometimes inside a JWT. The frontend calls `ability.update(unpackRules(rules))`. Packing makes the serialized rules about 2x smaller. — [CASL @casl/ability/extra API](https://casl.js.org/v4/en/api/casl-ability-extra/); [CASL issue #44 "Decrease serialized rules size"](https://github.com/stalniy/casl/issues/44)
- CASL rules do not have to be defined in code with `AbilityBuilder`. They can be plain JSON, "especially if your rules are dynamic (i.e., stored in database or managed by admin users)". This is what makes sending them to the client possible. — [CASL docs source: define-rules](https://raw.githubusercontent.com/stalniy/casl/master/docs-src/src/content/pages/guide/define-rules/en.md)
- Figma kept its permission logic in two places: Ruby (Sinatra) and TypeScript (LiveGraph). The two copies drifted apart and gave inconsistent answers. Figma fixed this with a JSON-serializable policy DSL. One TypeScript definition compiles to a neutral format, and small evaluators run it in Ruby, TypeScript and Go. Each evaluator took "two to three days for a senior engineer". (March 2024) — [Figma: How we built a custom permissions DSL](https://www.figma.com/blog/how-we-rolled-out-our-own-permissions-dsl-at-figma/)
- ASVS 5.0 8.3.1 (L1): "Verify that the application enforces authorization rules at a trusted service layer and doesn't rely on controls that an untrusted consumer could manipulate, such as client-side JavaScript." — [OWASP ASVS 5.0 V8](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x17-V8-Authorization.md)
- ASVS 5.0 8.3.2 (L3): changes to values that authorization decisions depend on must take effect immediately. — [OWASP ASVS 5.0 V8](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x17-V8-Authorization.md)
- OWASP Authorization Cheat Sheet: permission "should be validated correctly on every request, regardless of whether the request was initiated by an AJAX script, server-side, or any other source". — [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)
- A01:2021 lists "Bypassing access control checks by modifying the URL, internal application state, or the HTML page, or by using an API attack tool" and "force browsing" among common weaknesses. Hiding buttons in the UI stops neither. — [OWASP Top 10 2021 A01](https://top10.owasp.org/2021/A01_2021-Broken_Access_Control)
- A01:2021 also says OWASP recommends short-lived JWTs so the attack window stays small. This matters if packed rules are stored in a token. — [OWASP Top 10 2021 A01](https://top10.owasp.org/2021/A01_2021-Broken_Access_Control)

### Inferences
- Trade-offs between the two main patterns:
  - **Global list from `/me`** (for example `["payments:refund", ...]` or CASL rules):
    - Pros: one request; works for navigation and menus; cheap to cache.
    - Cons: the list goes stale when roles change (conflicts with the spirit of ASVS 8.3.2); it gets large when there are many tenants or resources; it shows the whole permission model, including sensitive conditions in CASL rules, to anyone who opens devtools; it cannot express per-object decisions without also sending the conditions.
  - **Per-resource flags** (the GitHub style):
    - Pros: the server has already made the per-object decision, including ownership, tenant and state rules, so the client never needs policy logic and the flags are fresh with every fetch; hard to get wrong.
    - Cons: every serializer has to compute the flags, which costs performance on list endpoints (Figma reported permission checks at about 20% of its database load); flags exist only for fetched objects.
  - A common hybrid: coarse capabilities from `/me` for navigation, per-object `can_*` flags for buttons on detail pages.
- If rules go into a JWT, the client's copy stays out of date until the token is refreshed. Keep tokens short-lived, or refresh `/me` after any role change.
- Whichever pattern is used, generate the frontend copy from the same source as the server policy (Figma's approach, or CASL's shared JSON rules). Otherwise the UI and server drift apart and users see buttons that fail or miss actions they are allowed to take.

### Gaps
- I did not fetch CASL's current v6 docs directly (the site's redirects failed). CASL claims come from the v4 API page and the docs source. I found no explicit CASL statement that frontend checks are cosmetic only.
- I found no primary source measuring the cost of permission flags in list responses, apart from Figma's 20% database-load figure for permission checks.

## 2. How do teams test authorization at scale?

### Takeaway
The pattern with the best evidence is an explicit role-by-permission matrix: a table-driven test for each permission that lists *every* role, including an explicit `false` for roles that must be denied. Add a fail-closed "was authorize called?" check on every controller action, and generate code and docs from declarative permission definitions so nothing drifts. GitLab, Pundit and Figma each show parts of this.

### Cited Findings
- GitLab permission specs:
  - one `describe` block per permission;
  - `where(:current_user, :allowed)` tables listing every role (for example `ref(:guest) | false`, `ref(:developer) | true`), run with `with_them` and `expect_allowed` / `expect_disallowed`;
  - "explicit `false` values are as important as `true` values because they document the intended access boundary."

  — [GitLab permissions testing guidelines](https://docs.gitlab.com/development/permissions/testing_guidelines)
- GitLab has issues open to rewrite older policy specs into this matrix pattern, "testing all roles and admin/non-admin combinations". — [GitLab issue #513159](https://gitlab.com/gitlab-org/gitlab/-/issues/513159)
- GitLab's DeclarativePolicy splits permissions into *conditions* (boolean checks that can read the database or environment) and *rules* (static combinations that enable or prevent abilities). Everything goes through `Ability.allowed?`. — [GitLab DeclarativePolicy framework](https://docs.gitlab.com/ee/development/policies.html)
- GitLab custom roles:
  - permissions are declared in YAML under `ee/config/custom_abilities`, and policy rules are generated from those files;
  - a generator (`rails generate gitlab:custom_roles:code --ability X`) updates the permission validation schema and creates an empty spec file;
  - rake tasks (`gitlab:custom_roles:compile_docs`, `gitlab:graphql:compile_docs`) rebuild the docs from the YAML.

  — [GitLab custom role development guidelines](https://docs.gitlab.com/development/permissions/custom_roles/)
- Pundit: `after_action :verify_authorized` and `verify_policy_scoped` raise an error if an action never called `authorize` or `policy_scope`. Actions opt out explicitly with `skip_authorization` or `skip_policy_scope`. Pundit warns: "This verification mechanism only exists to aid you while developing your application, so you don't forget to call `authorize`. It is not some kind of failsafe mechanism." — [Pundit README](https://github.com/varvet/pundit)
- Figma:
  - a static analyzer runs at build time over its permissions DSL and flags mistakes such as comparing a field that may be null without a guard; it "was able to catch a few other bugs that might have surfaced in production";
  - Figma also built a web debugger and a CLI that show, step by step, how a policy was evaluated;
  - DENY policies override ALLOW.

  — [Figma permissions DSL](https://www.figma.com/blog/how-we-rolled-out-our-own-permissions-dsl-at-figma/)
- Figma also describes negative unit tests, end-to-end tests in staging and production, and ongoing security review as part of catching authorization and data-exposure problems. — [Figma: Visibility at scale](https://www.figma.com/blog/visibility-at-scale-how-figma-detects-sensitive-data-exposure/) (from the search summary; I did not fetch the full page)
- OWASP Authorization Cheat Sheet: write unit and integration tests that check access is denied by default and that processing stops when a check fails. It adds that automated tests do not replace manual security testing. — [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)
- A01:2021 prevention list: "Developers and QA staff should include functional access control unit and integration tests." — [OWASP Top 10 2021 A01](https://top10.owasp.org/2021/A01_2021-Broken_Access_Control)
- OWASP Multi-Tenant cheat sheet: "Test isolation through the same role, connection path, and pooling mode used by the application." Tests run as a database superuser pass even when RLS is broken. — [OWASP Multi-Tenant Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html)

### Inferences
- A layered test stack:
  1. **Policy unit tests** as full role-by-action matrices (GitLab style).
  2. **Request specs** proving each endpoint actually calls the policy. Pundit's check catches forgotten calls, not wrong ones.
  3. **A route inventory check in CI**: list all routes and fail if a route has neither a policy nor an explicit public or skip annotation.
  4. **A committed snapshot of the permission matrix**, generated from the policy definitions, so any change to the matrix shows up as a readable diff in code review. This generalises GitLab's YAML-to-docs step.
  5. **Cross-tenant tests** that use two tenants and the production database role.
- If a role-to-permission map exists as data, the matrix tests can be generated from it. But the expected values must come from an independent source (a reviewed snapshot). Otherwise the test just repeats the implementation back to itself.

### Gaps
- I found no primary engineering-blog source from Shopify or Stripe on authorization testing.
- I found no primary source describing property-based tests for authorization in production. This is plausible practice, but unsourced.
- I found no authoritative write-up of CI linters that require every route to declare a policy, beyond Pundit's runtime check. Examples in other frameworks, such as NestJS global guards or Django custom checks, were not researched.

## 3. Auditing: should denied authorization attempts be logged, which fields, how should they feed alerts, and what do ASVS and A01 recommend?

### Takeaway
Yes. OWASP lists authorization failures as events to "always log". A01:2021 says to "log access control failures, alert admins when appropriate (e.g., repeated failures)" and to rate limit. Each log entry should answer when, where, who and what, include the server-verified tenant, and never include tokens, session IDs or card data.

### Cited Findings
- OWASP Logging Cheat Sheet:
  - lists "Authorization (access control) failures" among events to always log;
  - each event records **when** (timestamp in international format), **where** (application ID, service, URL or page, code location), **who** (user identity, source IP or device ID) and **what** (event type, severity, description);
  - never log passwords, session IDs, access tokens, sensitive PII, bank or cardholder data, encryption keys, or connection strings.

  — [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
- A01:2021 prevention list, verbatim:
  - "Except for public resources, deny by default."
  - "Implement access control mechanisms once and re-use them throughout the application, including minimizing Cross-Origin Resource Sharing (CORS) usage."
  - "Model access controls should enforce record ownership rather than accepting that the user can create, read, update, or delete any record."
  - "Log access control failures, alert admins when appropriate (e.g., repeated failures)."
  - "Rate limit API and controller access to minimize the harm from automated attack tooling."
  - Invalidate stateful sessions on the server at logout, and keep JWTs short-lived.

  — [OWASP Top 10 2021 A01](https://top10.owasp.org/2021/A01_2021-Broken_Access_Control)
- A01:2021 statistics:
  - ranked #1 in the Top 10 2021;
  - maximum incidence rate 55.97%, average 3.81%;
  - 34 CWEs mapped;
  - 318,487 occurrences;
  - 19,013 CVEs.

  — [OWASP Top 10 2021 A01](https://top10.owasp.org/2021/A01_2021-Broken_Access_Control)
- OWASP Authorization Cheat Sheet: use consistent, parseable log formats with synchronized clocks, and avoid logging too much or too little. Handle every failed check, however unlikely it seems, without leaking sensitive information in error messages. — [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)
- OWASP Multi-Tenant cheat sheet:
  - "Include server-verified tenant context in tenant-scoped security and audit events";
  - monitor access denials to spot cross-tenant enumeration and privilege-escalation attempts.

  — [OWASP Multi-Tenant Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html)
- ASVS 5.0 V8 requirements that relate to auditability:
  - 8.1.1 (L1): documented rules for function-level and data-specific access;
  - 8.1.2 (L2): field-level read and write rules;
  - 8.3.3 (L3): decisions use the *originating subject's* permissions, not those of an intermediary service;
  - 8.4.1 (L2): cross-tenant controls in multi-tenant apps.

  ASVS 5.0 covers logging in a separate chapter (V16), which I did not fetch. — [OWASP ASVS 5.0 V8](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x17-V8-Authorization.md)

### Inferences
- A suggested denied-event schema, following OWASP's when/where/who/what:
  - `timestamp`
  - `request_id` / `trace_id`
  - `actor_id`
  - `actor_type` (user, API key or service)
  - `tenant_id` (server-verified)
  - `roles` at decision time
  - `action` / `permission` requested
  - `resource_type` and `resource_id`
  - `resource_tenant_id` (this is what reveals cross-tenant probing)
  - `decision` and `reason` / `policy_rule` that denied it
  - `route`, `http_method`, `source_ip`, `user_agent`

  Leave out request bodies, because they can contain card or PII data.
- Useful alerts:
  - N denials per actor within a time window;
  - denials where `resource_tenant_id != tenant_id`;
  - sequential-ID enumeration, meaning many distinct `resource_id`s denied;
  - any denied attempt to assign a role.

  Pair these with rate limits on the same keys. Expect normal UI-driven denials (stale buttons), so tune thresholds and prefer per-object flags to cut that noise.
- Successful privileged actions, such as role grants, permission changes and impersonation, belong in the durable audit trail too. That trail doubles as SOC 2 evidence (section 5).

### Gaps
- I did not fetch the text of ASVS 5.0 V16 (Security Logging) or the 4.0.3 V4 and V7 requirements. The numbering of the logging requirement for access-control failures is unverified.

## 4. Common authorization bugs in multi-tenant SaaS and the structural defenses against them

### Takeaway
The most common failures:
- IDOR/BOLA: an object is fetched by ID without an ownership or tenant check;
- a tenant is taken from client input;
- a query is missing its tenant scope, including in background jobs and cache keys;
- a role-assignment path lets a user grant more than they hold;
- mass assignment of role or admin fields.

The structural defenses are to derive tenant context on the server, scope queries by default with Postgres RLS as a backstop, allow-list writable fields per role, and check that the target role is at most the granter's role.

### Cited Findings
- ASVS 5.0:
  - 8.2.2 (L1): data-specific access restricted "to mitigate insecure direct object reference (IDOR) and broken object level authorization (BOLA)";
  - 8.2.3 (L2): field-level access restricted "to mitigate broken object property level authorization (BOPLA)";
  - 8.4.1 (L2): "multi-tenant applications use cross-tenant controls to ensure consumer operations will never affect tenants with which they do not have permissions to interact."

  — [OWASP ASVS 5.0 V8](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x17-V8-Authorization.md)
- OWASP Authorization Cheat Sheet: "Just because a user has access to an object of a particular type does not mean they should have access to every object". Check every specific object, and avoid predictable or direct identifiers where practical. — [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)
- OWASP Multi-Tenant cheat sheet:
  - "Treat client-supplied tenant identifiers as selectors only. Verify that the authenticated principal is authorized to act in the selected tenant."
  - Resolve the tenant early in middleware from verified credentials and current membership.
  - Use Postgres RLS on tenant-owned tables, and "Do not serve ordinary tenant-scoped requests through a privileged connection" (superuser or BYPASSRLS roles skip RLS).
  - Use `SET LOCAL` so the tenant setting lasts only for the transaction and cannot leak across pooled connections.
  - "Do not use a shared cache key for data or authorization that varies by tenant."
  - "Carry verified tenant context through tenant-scoped asynchronous work and re-establish authorization at the consumer."

  — [OWASP Multi-Tenant Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html)
- A secondary source (a pentest vendor, not primary data) reports that BOLA/IDOR make up the majority of cross-tenant findings in its multi-tenant SaaS assessments. It also notes that developers often trust a tenant ID from the URL or a header. — [AppSecure: Pentesting multi-tenant SaaS (2026)](https://www.appsecure.security/blog/penetration-testing-for-multi-tenant-saas-architectures)
- Two further failure modes from secondary sources:
  - background jobs that trust the tenant ID in their payload instead of re-checking the record they are about to read or write;
  - AI-generated queries that leave out `WHERE tenant_id = ?`.

  — [Tomoda Hinata: multi-tenant data isolation guide](https://tomodahinata.com/en/blog/multi-tenant-saas-data-isolation-authorization-design-guide); [Autonoma: multi-tenant testing](https://getautonoma.com/blog/multi-tenant-saas-testing)
- OWASP Mass Assignment Cheat Sheet:
  - canonical example: an attacker adds `isAdmin=true` to a profile-update POST and the framework binds it;
  - defenses: allow-list the fields that may be bound (recommended), or use DTOs that contain only editable fields;
  - block-lists are weaker, because a sensitive field added later may be forgotten.

  — [OWASP Mass Assignment Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Mass_Assignment_Cheat_Sheet.html)
- Pundit supports per-policy permitted attributes, so writable fields can depend on the user's role. — [Pundit README](https://github.com/varvet/pundit)
- Real-world privilege escalation through role management:
  - HackerOne's own program: a member with "Program" permission could escalate to "Admin" and so gain "Reward" and "Report" permissions — [HackerOne report #605720](https://hackerone.com/reports/605720)
  - Bitwarden: organization-admin privilege escalation — [HackerOne report #272570](https://hackerone.com/reports/272570)
  - Omise: a user kept admin access after being downgraded, a stale-permission bug — [HackerOne report #1607756](https://hackerone.com/reports/1607756)
  - a curated index of top disclosed authorization reports — [reddelexc/hackerone-reports TOPAUTHORIZATION](https://github.com/reddelexc/hackerone-reports/blob/master/tops_by_bug_type/TOPAUTHORIZATION.md)
- A01:2021 includes "Elevation of privilege. Acting as a user without being logged in or acting as an admin when logged in as a user", "Metadata manipulation, such as replaying or tampering with a JSON Web Token (JWT) access control token", and "Accessing API with missing access controls for POST, PUT and DELETE". — [OWASP Top 10 2021 A01](https://top10.owasp.org/2021/A01_2021-Broken_Access_Control)
- Figma's DENY-overrides-ALLOW model lets a restriction such as a blocked or suspended user win over any grant. — [Figma permissions DSL](https://www.figma.com/blog/how-we-rolled-out-our-own-permissions-dsl-at-figma/)

### Inferences
Structural defenses, mapped to each bug:
- **IDOR / BOLA** → always load records through a scoped finder (`current_tenant.payments.find(id)`), never `Payment.find(id)`. Add RLS as defense in depth. Use non-guessable IDs, which is a mitigation, not a control.
- **Tenant from the client** → resolve the tenant in middleware from the session's membership. Any tenant in the URL is only a selector and must be checked against that membership.
- **Missing scope in jobs** → pass `tenant_id` and `actor_id` in the job payload, and re-run the authorization and scope checks in the worker.
- **Cache poisoning across tenants** → include the tenant in every cache key.
- **Role-assignment escalation** → a user may grant only roles at or below their own, and never the owner role unless they are the owner. Protect the last owner and admin from removal. Make role changes take effect immediately (ASVS 8.3.2) and write them to the audit log.
- **Mass assignment of `role` / `is_admin` / `tenant_id`** → use allow-listed params or DTOs, change roles only through a dedicated endpoint, and never bind `tenant_id` from the body.
- **Missing checks on mutation verbs** → enforce authorization in one central layer (A01: "implement once and re-use"), with a CI check that every route is covered.

### Gaps
- I found no reliable, primary statistic on how often each bug class occurs in multi-tenant SaaS specifically. The "majority of findings" claim comes from vendors.
- I did not open the individual HackerOne reports to confirm details beyond their titles and search snippets.

## 5. How to make the permission matrix readable for non-engineers and auditors (generated docs, SOC 2 evidence)

### Takeaway
Keep the matrix as declarative data, and generate the human-readable table and docs from it in CI, as GitLab does from YAML. ASVS 8.1.x already requires written authorization rules. For SOC 2 (CC6.2 and CC6.3), auditors ask for a role matrix plus periodic reviews of who holds which role, with approver identity and timestamps. Recording every grant, change and revocation as an audit event produces that evidence automatically.

### Cited Findings
- ASVS 5.0:
  - 8.1.1 (L1): "authorization documentation defines rules for restricting function-level and data-specific access based on consumer permissions and resource attributes";
  - 8.1.2 (L2): field-level read and write rules;
  - 8.1.3–8.1.4 (L3): the environmental and contextual attributes used in decisions.

  — [OWASP ASVS 5.0 V8](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x17-V8-Authorization.md)
- GitLab generates its custom-ability documentation (`rake gitlab:custom_roles:compile_docs`) and its GraphQL docs from the YAML permission definitions, keeping docs in step with enforcement. — [GitLab custom roles dev guide](https://docs.gitlab.com/development/permissions/custom_roles/)
- GitLab's finance handbook publishes an authorization matrix as a readable table for approvals. This is an organisational example, not an application-permission one. — [GitLab Handbook: Authorization Matrix](https://handbook.gitlab.com/handbook/finance/authorization-matrix/)
- SOC 2:
  - CC6.2 covers granting and removing credentials, with periodic review to find inappropriate access;
  - CC6.3 covers authorizing and changing access based on roles and least privilege, with periodic review of access roles and rules.

  — [ISMS.online CC6.2](https://www.isms.online/soc-2/controls/logical-and-physical-access-controls-cc6-2-explained/); [WatchDog Security CC6.3](https://watchdogsecurity.io/soc2/authorize-and-modify-access-based-on-roles)
- Evidence auditors usually request:
  - user lists with assigned roles;
  - user role matrices;
  - access-request history with the approver's identity;
  - revocation timestamps and offboarding records.

  Recording each grant, change and revocation as a separate audit event gives a timestamped chain of evidence without screenshots. — [IntSignal: SOC 2 UAR evidence](https://www.intsignal.com/signal/soc-2-user-access-review-evidence); [Bytebase: DB access control for SOC 2](https://www.bytebase.com/blog/database-access-control-for-soc2/) (vendor and consultancy sources, secondary)
- Figma's policy debugger and CLI show a step-by-step trace of why access was allowed or denied. That kind of explanation is also what reviewers need to see. — [Figma permissions DSL](https://www.figma.com/blog/how-we-rolled-out-our-own-permissions-dsl-at-figma/)

### Inferences
- Recommended artifact: a CI job renders the role-to-permission map as a table, with roles as columns and permissions as rows, a short plain-English description for each permission, and markings for sensitive actions such as refunds, payouts and role management. The table is committed, for example as `docs/permissions.md`. A diff check fails CI if it is stale, so any change to the matrix needs PR approval, which gives change-management evidence (CC8.1).
- For access reviews, export user × role × tenant with `granted_by` and `granted_at` from the role-assignment audit log. Have role owners review it quarterly and store the sign-off.
- The same permission descriptions can feed the admin UI's role editor, so customers, auditors and engineers all see one vocabulary.

### Gaps
- I found no primary AICPA text for the CC6.x points of focus. The descriptions come from secondary compliance sites.
- I found no public example from a major SaaS company of a *generated* customer-facing role matrix beyond GitLab. GitHub's and GitLab's user-facing "permissions and roles" docs pages exist but were not checked for whether they are generated.
