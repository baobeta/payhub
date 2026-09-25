# Authorization Architectures and Policy Engines: RBAC vs ABAC vs ReBAC, and When to Leave In-App Checks

Research date: 2026-09-25. About 25 tool calls. Several primary sources (the Airbnb Himeji Medium post, Carta's Medium posts, InfoQ) were blocked (403/405/TLS errors), so some claims about them come from search-result snippets and are marked. Items labeled "background knowledge (unverified this session)" are my own general knowledge, not fetched sources. The report writer should treat them as leads to check, not as citations.

## Q1. What the engines are: model, deployment shape, and trade-offs

### Takeaway
The engines fall into two families. **Policy-as-code evaluators** (OPA/Rego, Cedar/AVP, Cerbos, Casbin, Oso's Polar) evaluate rules over attributes or data that the caller supplies, or that is pushed to them. They run embedded or as a sidecar, and they are fast and stateless, but moving the data to them is your problem. **Zanzibar-style relationship stores** (Zanzibar, SpiceDB, OpenFGA/Auth0 FGA, Airbnb Himeji, Carta AuthZ) are stateful central services. They hold relationship tuples, so they answer "list what user X can see" well, but they add a dual-write/data-sync problem and have to handle consistency (the "new enemy" problem) explicitly.

### Cited Findings
**Google Zanzibar (USENIX ATC 2019)**
- Zanzibar "scales to trillions of access control lists and millions of authorization requests per second" with "95th-percentile latency of less than 10 milliseconds and availability of greater than 99.999% over 3 years of production use". Used by Calendar, Cloud, Drive, Maps, Photos and YouTube. — [USENIX ATC'19, Pang et al.](https://www.usenix.org/conference/atc19/presentation/pang)
- It gives "external consistency": authorization decisions "respect causal ordering of user actions" across ACL and content changes. — [USENIX ATC'19](https://www.usenix.org/conference/atc19/presentation/pang)
- **New enemy problem:** unauthorized access can happen when permission changes and the resources they protect are not updated together consistently. The Zanzibar paper introduced "zookies" to solve it: ACL checks must respect the order in which users modify ACLs and object contents. — [Authzed Docs: Consistency](https://authzed.com/docs/spicedb/concepts/consistency); [Authzed: ZedTokens/Zookies](https://authzed.com/blog/zedtokens)
- SpiceDB's version is the ZedToken, an opaque token that encodes a causal timestamp. The app requests a ZedToken when content changes, stores it with the document, and sends it with later CheckPermission calls so that cached results older than that point are not used. Consistency can be chosen per request. — [Authzed: ZedTokens](https://authzed.com/blog/zedtokens); [Authzed Docs: Consistency](https://authzed.com/docs/spicedb/concepts/consistency)
- Authzed writes that preventing the new enemy problem depends on datastore guarantees, and that CockroachDB differs from Spanner here. — [Authzed: Spanner vs CockroachDB](https://authzed.com/blog/prevent-newenemy-cockroachdb)

**SpiceDB / Authzed**
- SpiceDB is an open-source database inspired by Zanzibar that "decouples authorization data from your applications and stores it in a centralized service". — [SpiceDB GitHub](https://github.com/authzed/spicedb); [AuthZed SpiceDB](https://authzed.com/spicedb)
- It adds ABAC-style "Caveats", sponsored by Netflix. Caveats let a check use both relationships and attributes supplied at check time, instead of storing all authorization state as relations. Netflix found the original pure-ReBAC model "poorly suited for Netflix's core requirements for application identities". This is vendor-authored and gives no metrics. — [AuthZed customer story: Netflix](https://authzed.com/customers/netflix)
- For bootstrapping a move off bespoke authorization, `zed` can import from PostgreSQL. It generates a schema and a mapping, then syncs the data into relationships. — [Authzed blog: zed import](https://authzed.com/blog/zed-import)

**Data sync / dual-write (applies to every stateful central service)**
- Dual-write problem: the same data has to live in the primary DB and in SpiceDB, and the two cannot share a transaction. Failures and races cause false negatives (blocked users) or false positives (a security risk). Mitigations from a Google/Canva engineer's talk (Aug 2025): periodic cron full-reconciliation (Google synced "100 millions of users in just a couple of hours", but discrepancies can last hours), targeted "micro-syncs" with delayed reprocessing, transactional outbox, and conditional writes with version fields. — [AuthZed blog, Sep 2025](https://authzed.com/blog/the-dual-write-problem-in-spicedb-a-deep-dive-from-google-and-canva-experience)
- CAUTION: the fetch summarizer said Canva uses SpiceDB for a "home automation platform". That looks like a worked example from the talk being misread, not Canva's product. Do not repeat it without checking.

**OpenFGA / Auth0 FGA**
- OpenFGA is a ReBAC engine inspired by Zanzibar, created by Okta employees. It is the base of the commercial SaaS Auth0 FGA, and the CNCF accepted it as an incubating project in Nov 2025. — [CNCF, 2025-11-11](https://www.cncf.io/blog/2025/11/11/openfga-becomes-a-cncf-incubating-project/)
- Listed adopters: Grafana Labs ("user authorization and RBAC are migrating to OpenFGA"), Canonical (Juju, LXD, Ubuntu Pro), Docker, Headspace (subscription entitlements, content availability by region and language), Sourcegraph, and SigNoz. — [OpenFGA ADOPTERS.md](https://github.com/openfga/community/blob/main/ADOPTERS.md)

**OPA / Rego**
- Netflix used OPA to enforce access control in microservices across many languages and frameworks, for thousands of instances. This comes from a secondary vendor summary (Permit.io) of Netflix's KubeCon/Velocity talks. — [Permit.io on Netflix](https://www.permit.io/blog/netflix-authz); [O'Reilly Velocity 2018: Netflix distributed authorization](https://conferences.oreilly.com/velocity/vl-ca-2018/public/schedule/detail/66606.html); [OPA ADOPTERS.md](https://github.com/open-policy-agent/opa/blob/main/ADOPTERS.md)
- A sidecar or embedded OPA avoids a network hop and decides in milliseconds, but keeping policy and data in sync across instances is the main challenge. Data comes in through bundles (pull) or the REST API (push), and tools like OPAL exist only to push data changes into OPA. — [Permit.io: OPAL](https://www.permit.io/blog/introduction-to-opal); [arXiv 2009.02114 survey of microservice authz patterns](https://arxiv.org/pdf/2009.02114)

**AWS Cedar / Amazon Verified Permissions**
- Cedar was published at OOPSLA 2024 (PACMPL vol. 8). It is designed to be expressive, fast, safe and *analyzable*. Most operators take constant time and loops are linear, and the authors report Cedar is **42–60x faster than Rego** in their benchmarks. These are the authors' own benchmarks. — [Cedar paper, arXiv 2403.04651](https://arxiv.org/pdf/2403.04651); [ACM DL](https://dl.acm.org/doi/10.1145/3649835)
- Amazon Verified Permissions is a fully managed authorization service using Cedar. — [AVP docs](https://docs.aws.amazon.com/verifiedpermissions/); AWS has published a guide to migrating from OPA to AVP — [AWS Security Blog](https://aws.amazon.com/blogs/security/migrating-from-open-policy-agent-to-amazon-verified-permissions/)
- In Cedar, any matching `forbid` overrides every `permit`, and the default is deny. — [Cedar docs: Authorization](https://docs.cedarpolicy.com/auth/authorization.html)

**Oso**
- Oso Cloud is sold as authorization-as-a-service. Oso argues that building your own authorization service needs a low-latency, highly available service that can model roles and relationships, version policies, and answer both yes/no and list queries, and that Google, Slack and Airbnb each took "months or years" with dedicated teams (vendor claim). — [Oso: Authorization as a Service](https://www.osohq.com/cloud/authorization-service)
- Oso Cloud also offers "local authorization", which evaluates against data in the app's own DB to reduce sync. Chris Richardson walks through it in a 2025–26 series. — [microservices.io Part 5](https://microservices.io/post/architecture/2025/12/09/microservices-authn-authz-part-5-using-an-authorization-service.html); [Part 6](https://microservices.io/post/architecture/2026/02/13/microservices-authn-authz-part-6-oso-local-authorization.html)

**Cerbos**
- Cerbos is a stateless policy decision point (PDP) with policies written in YAML. It is called over an API, and the caller supplies principal and resource attributes. — [Cerbos: stateless externalized authorization](https://www.cerbos.dev/news/stateless-externalized-authorization-for-scalable-applications)

### Inferences
- Deployment taxonomy:
  - **Embedded library:** Casbin, the old open-source Oso/Polar library, OPA as a Go library or Wasm, and the Cedar SDK.
  - **Sidecar or local PDP:** OPA, Cerbos, and the AVP local agent pattern.
  - **Central stateful service:** Zanzibar, SpiceDB, OpenFGA, Auth0 FGA, Oso Cloud, AVP, Himeji, Carta AuthZ.
  - The main trade-off moves along that axis. An embedded engine has near-zero latency and no data-sync layer, but gives no cross-service view and cannot answer "list objects". A central store gives one source of truth, list/filter queries and audit, but costs a network hop, dual writes and consistency tokens.
- The new enemy problem matters only where authorization data is cached or replicated separately from the content, which means central relationship stores. An in-app check inside the same DB transaction does not have it.
- Background knowledge (unverified this session): Casbin models RBAC and ABAC through a PERM config (request, policy, effect, matchers) with many language ports. Oso deprecated its open-source Polar library around 2023 in favor of Oso Cloud. Cerbos Hub is its managed control plane. These need checking against [casbin.org](https://casbin.org) and the Oso and Cerbos docs.

### Gaps
- I could not fetch the full Zanzibar PDF, so the exact wording of the two "new enemy" examples (removing a user and then adding content, and the parent-folder ACL example) is not quoted here.
- I found no independent (non-vendor) latency benchmark that compares SpiceDB, OpenFGA and Cedar head-to-head. The only numeric comparison is Cedar vs Rego, published by the Cedar authors.

## Q2. Documented company adoptions and why they moved off in-app checks

### Takeaway
The trigger is almost always **service decomposition or multiple codebases** that need the same answer. Pure scale is rarely the trigger. Airbnb (moving to SOA), Carta (breaking up its monolith in 2019) and Figma (logic drifting between its Ruby and LiveGraph stacks) all moved because authorization logic was duplicated or drifting across services, not because a single app's checks were slow. Even then, companies often build a custom solution (Figma) instead of adopting Zanzibar or OPA.

### Cited Findings
- **Google:** Zanzibar is one system serving Calendar, Cloud, Drive, Maps, Photos and YouTube, with trillions of ACLs. — [USENIX ATC'19](https://www.usenix.org/conference/atc19/presentation/pang)
- **Airbnb Himeji** (Alan Yao, 2021): a central system based on Zanzibar that "unifies authorization data and logic". It went from 0 checks in March 2020 to 850k entities/sec in March 2021, with 99.9990% availability, **P50 latency 1.8 ms**, and a target cache hit rate of about 98%. Differences from Zanzibar: the orchestration tier is separate from the cache tier, cache shards are invalidated from published DB mutations, and it stores on Amazon Aurora rather than Spanner. These figures come from search snippets of the original post and InfoQ, because direct fetches failed. — [Airbnb Tech Blog](https://medium.com/airbnb-engineering/himeji-a-scalable-centralized-system-for-authorization-at-airbnb-341664924574); [InfoQ, May 2021](https://www.infoq.com/news/2021/05/airbnb-himeji/)
- **Carta AuthZ:** based on Zanzibar and built on RelationTuples that form a permissions graph. Work started in **mid-2019, when Carta began decomposing its monolith** and new services needed a way to authorize incoming requests. A companion post is titled "User authorization in less than 10 milliseconds". From search snippets, because the Medium pages returned 403. — [Building Carta: AuthZ](https://medium.com/building-carta/authz-cartas-highly-scalable-permissions-system-782a7f2c840f); [Building Carta: <10ms](https://medium.com/building-carta/user-authorization-in-less-than-10-milliseconds-f20d277fec47)
- **Figma** (Jorge Silva, 2024-03-13): Figma evaluated **OPA, Zanzibar and Oso and rejected all three**. It built its own DSL: IAM-style JSON policies with allow/deny effects (deny wins), authored in TypeScript, and evaluated by small evaluators in Ruby, TypeScript and Go. Problems with the earlier in-code system:
  - The `has_access?` methods "were really long and complicated, with many optional parameters. Engineers were nervous to modify them."
  - Permission checks were about **20% of database load**.
  - Logic duplicated between Sinatra and LiveGraph drifted, causing incidents.

  The key design goal was to fully separate policy logic from data loading. Lazy loading and short-circuiting "more than halv[ed]" evaluation time. — [Figma blog](https://www.figma.com/blog/how-we-rolled-out-our-own-permissions-dsl-at-figma/)
- **Netflix:** used OPA across the stack for HTTP, gRPC and SSH at thousands of instances (via secondary sources). Later sponsored SpiceDB Caveats for ABAC on application identities. — [Permit.io](https://www.permit.io/blog/netflix-authz); [AuthZed: Netflix](https://authzed.com/customers/netflix)
- **Canva:** runs SpiceDB as a centralized authorization system. A Canva engineer with prior experience on Zanzibar at Google presented on handling dual writes (Aug 2025). — [AuthZed blog](https://authzed.com/blog/the-dual-write-problem-in-spicedb-a-deep-dive-from-google-and-canva-experience)
- **Grafana Labs** is migrating its RBAC to OpenFGA. **Canonical** uses OpenFGA across Juju, LXD and Ubuntu Pro. — [OpenFGA ADOPTERS](https://github.com/openfga/community/blob/main/ADOPTERS.md)
- **GitHub:** the only thing found is that GitHub employees are among SpiceDB contributors. That is not evidence that GitHub runs SpiceDB in production. — [SpiceDB README](https://github.com/authzed/spicedb/blob/main/README.md)

### Inferences
- The migration threshold in these case studies is qualitative. The signals are: two or more services or codebases that need the same permission logic; sharing and hierarchy features (folders, teams, orgs) that need graph traversal or "list what I can see"; and authorization queries taking a meaningful share of DB load (Figma's 20%). No source gives a headcount or QPS threshold.
- Companies that went central (Airbnb, Carta) had Zanzibar-shaped products: sharing, nested resources and org hierarchies. Figma had a similar product but chose attribute-style policies with its own data loaders to avoid the dual-write problem. That is a sign that ReBAC-as-a-service is not the default answer even at large scale.

### Gaps
- **Notion:** I found no public engineering write-up of its authorization architecture.
- **GitHub:** found nothing on its production authorization system beyond SpiceDB contributors.
- **Canva:** no public numbers on scale or on when it adopted SpiceDB.
- I could not get Carta's latency figures or the exact pain points of its pre-AuthZ Django permissions (pages blocked).

## Q3. When NOT to use a policy engine, and the recommended evolution path

### Takeaway
Vendors themselves recommend starting simple. Oso says you "don't need to start there" and quotes "spend only as much time as you need... and not a moment more". The consistent path is: (1) in-code checks → (2) a centralized, declarative authorization module inside the app (one place, testable, documented) → (3) an external engine or service once logic is duplicated across services or languages, customers need custom roles, or policy changes are slowing deploys. The "warning signs" vendors publish are the practical triggers.

### Cited Findings
- Oso: "If you're seeing authorization logic duplicated across services or policy changes are slowing down deploys, it's time to consider an authorization service… you don't need to start there, but should plan for it before things get messy." — [Oso: Authorization as a Service](https://www.osohq.com/cloud/authorization-service)
- Oso Authorization Academy: "spend only as much time as you need to spend on authorization – and not a moment more." — [Oso Authorization Academy](https://www.osohq.com/academy/authorization-academy)
- Oso's "5 warning signs" (2025-05-21):
  1. permissions stored in a dictionary or data class that "quickly becomes unmaintainable";
  2. scattered enforcement, where "You can't update a role's permissions without making changes in a dozen places";
  3. nobody can answer "What exactly can an admin do again?";
  4. no support for enterprise custom roles;
  5. a monolith-to-microservices split that fragments permissions.

  The recommended middle step is a "declarative authorization model... that lives outside your app code, but integrates seamlessly with it". The article gives no numeric thresholds. — [Oso blog](https://www.osohq.com/post/app-authorization-warning-signs)
- Oso's "enforcement best practices" doc (centralize enforcement points; filter lists at the data layer). — [Oso docs](https://www.osohq.com/docs/app-integration/integrate-authorization/enforcement-best-practices)
- Cerbos (vendor) accepts that home-grown authorization "may be easy" at first, but says it "gets more complex as a company's needs grow" and hardcoded rules become "a complex web of if-else statements". — [Cerbos blog](https://www.cerbos.dev/blog/taking-the-pain-out-of-authorization-and-user-permissions); [Cerbos: avoid authorization errors](https://www.cerbos.dev/blog/avoid-authorization-errors)
- Monolith vs microservices: in a monolith, "all requisite data for a single authorization decision was in a monolith's database", and that stops being true with microservices. — [Oso via search snippet](https://www-webflow.osohq.com/use-case/authorization-for-microservices)
- Figma is a counter-example to "buy an engine". Even at Figma's scale, the right step was a **custom in-house policy layer** that kept data loading in the app, not an external service. — [Figma blog](https://www.figma.com/blog/how-we-rolled-out-our-own-permissions-dsl-at-figma/)

### Inferences
- When NOT to adopt an external engine (drawn from the findings above plus the dual-write costs in Q1):
  - a single monolith or single DB;
  - a small, fixed role set (for example admin/operator/viewer);
  - no end-user sharing or resource hierarchy;
  - no customer-defined roles;
  - one language.

  In that situation an external engine adds a network hop, a second source of truth (dual writes), consistency tokens and an ops burden, and buys nothing. A single `Policy`/`can?(user, action, resource)` module with tests is the right level.
- Signals that stage 2 (the central in-app module) is due: checks are copied across controllers, jobs and views; nobody can list what a role can do; auditors ask for a permission matrix.
- Signals that stage 3 (an external engine) is due: a second service or language needs the same decisions; customers want custom roles or sharing; you need "list resources the user can access" across services; or policy changes need to ship separately from app deploys.
- Choosing among stage-3 engines:
  - **Stateless** (OPA/Cedar/Cerbos): when the app already has the attributes at request time.
  - **Zanzibar-style** (SpiceDB/OpenFGA): when permissions come from a large graph of relationships (sharing, nested folders, orgs) and you need reverse lookups.

### Gaps
- None of the vendor sources give a quantitative threshold (team size, number of services, roles or QPS). Any numeric rule of thumb in the final report would be the writer's own judgment, not sourced.
- No sourced independent practitioner essay (non-vendor) arguing against policy engines was found in this session. Almost all "when to adopt" guidance is vendor-authored and biased toward adopting.

## Q4. Separation of duties / maker-checker (approver ≠ requester) in RBAC, ABAC, ReBAC

### Takeaway
Standard RBAC (ANSI/INCITS 359) only has **role-level** separation of duty. Static SoD stops one user from *holding* conflicting roles, and dynamic SoD stops *activating* them in the same session. Neither can say "the approver of *this* payment must not be the person who requested *this* payment". That is an **instance-level** rule about a relationship between the principal and the resource, so it needs ABAC (for example a Cedar `forbid` when `principal == resource.requester`) or ReBAC (an exclusion such as `approver but not requester`), or an explicit business-rule check in the domain layer. In practice it is a business invariant that should be enforced in the domain or workflow, and optionally also in the policy layer.

### Cited Findings
- ANSI/INCITS 359-2004 RBAC has Core RBAC plus optional components (hierarchies, SSD, DSD). SoD constraints exist so that "fraud and major errors cannot occur without deliberate collusion of multiple users." — [NIST/INCITS 359 draft](https://xml.coverpages.org/NCITS-NIST-RBAC-Candidate.pdf); [Symas intro to INCITS 359](https://www.symas.com/post/an-introduction-to-role-based-access-control-ansi-incits-359-2004)
- **Static SoD** stops one user holding incompatible roles, for example "payment requestor" and "payment approver", and is enforced when roles are assigned. **Dynamic SoD** stops activating conflicting roles in the same session. Role hierarchies need care so that inheritance does not bypass SSD. — [Symas](https://www.symas.com/post/an-introduction-to-role-based-access-control-ansi-incits-359-2004); [Apache Fortress: what ANSI RBAC is](https://directory.apache.org/fortress/user-guide/1.3-what-rbac-is.html)
- Academic criticism: Ninghui Li et al. criticize how the ANSI standard specifies SoD. — [Li, "A Critique of the ANSI Standard on RBAC"](https://www.cs.purdue.edu/homes/ninghui/papers/aboutRBACStandard.pdf)
- Cedar: any satisfied `forbid` overrides all `permit`s. That makes a maker-checker guard a single deny rule layered over role-based permits. — [Cedar docs](https://docs.cedarpolicy.com/auth/authorization.html)
- Figma's DSL also uses IAM-style deny-overrides, which serves the same pattern. — [Figma blog](https://www.figma.com/blog/how-we-rolled-out-our-own-permissions-dsl-at-figma/)

### Inferences
- Example expressions (illustrative, not quoted from docs):
  - **Cedar/ABAC:** `forbid(principal, action == Action::"approve", resource) when { resource.requester == principal };`
  - **OPA/Rego:** `deny if { input.action == "approve"; input.resource.requested_by == input.user.id }`
  - **ReBAC (SpiceDB schema):** `permission approve = org->approver - requester`, using the exclusion operator. **OpenFGA:** `define can_approve: approver but not requester`.
  - **In-app:** a guard in the approval service or state machine: `raise if payment.requested_by_id == current_user.id`.
- RBAC SSD/DSD is still useful for coarse cases, such as "nobody may be both AP clerk and AP approver". But a payments or finance app usually lets the same person request some items and approve others, so the per-instance rule is the one that matters, and it lies outside pure RBAC.
- Maker-checker is best treated as a **domain invariant** enforced in the workflow or state transition, next to the data and inside the same transaction, so it cannot be bypassed by another code path and is not exposed to the new enemy or sync lag. Adding it to the policy layer as well gives UI hiding and audit, but the domain check should be the one you rely on. The same applies to related rules: N-of-M approvals, amount thresholds, and "approver must not have edited the payment after submission".

### Gaps
- NIST SP 800-162 (ABAC guide, 2014, updated 2019) was not fetched this session. Its definitions and its treatment of environment conditions and SoD should be cited from https://csrc.nist.gov/pubs/sp/800/162/upd2/final if the report needs them (URL from background knowledge, not verified this session).
- The SpiceDB exclusion (`-`) and OpenFGA `but not` syntax above come from background knowledge and were not fetched from their docs pages this session.
