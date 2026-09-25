# Rails Authorization and Multi-Tenant Scoping (libraries, large-app patterns, recommendation inputs)

Research date: 2026-09-25. Gem versions/dates pulled live from the RubyGems API (`https://rubygems.org/api/v1/gems/<name>.json` and `/api/v1/versions/<name>.json`). Open-source 37signals code was read from shallow clones of `basecamp/once-campfire` and `basecamp/fizzy` (HEAD as of 2026-09-23/24).

## 1. Pundit vs Action Policy vs CanCanCan vs Rolify (and others): design, scoping, verification, caching, testing, maintenance, pain points

### Takeaway
Pundit (plain Ruby policy classes + `Scope#resolve` + `verify_authorized`/`verify_policy_scoped`) is the de facto default and actively maintained (2.5.2, Sep 2025, ~111M downloads). Action Policy is the "Pundit plus" option (pre-checks, aliases, per-request result caching, failure reasons, first-class scopes and matchers) and is the most actively released (0.7.7, Sep 2026). CanCanCan is maintained but slow-moving (3.6.1, May 2024) and its single `Ability` file is the classic scaling pain point. Rolify is a role-assignment store, not an authorization engine, and is effectively dormant (6.0.1, Feb 2023).

### Cited Findings

**Maintenance / popularity (RubyGems API, fetched 2026-09-25)**
| Gem | Latest | Released | Prior releases | Total downloads |
|---|---|---|---|---|
| pundit | 2.5.2 | 2025-09-24 | 2.5.1 (2025-09-12), 2.5.0 (2025-03-03) | ~111.0M |
| cancancan | 3.6.1 | 2024-05-28 | 3.6.0 (2024-05-23), 3.5.0 (2023-03-05) | ~95.5M |
| rolify | 6.0.1 | 2023-02-02 | 6.0.0 (2021-04-25), 5.3.0 (2020-06-01) | ~25.1M |
| declarative_policy (GitLab) | 2.1.0 | 2026-03-13 | 2.0.1 (2025-08-24), 1.1.0 (2021-11-05) | ~30.9M |
| action_policy | 0.7.7 | 2026-09-03 | 0.7.6 (2026-01-13), 0.7.5 (2025-05-09) | ~7.9M |
| acts_as_tenant | 2.0.0 | 2026-09-21 | 1.0.1 (2023-12-14) | ~8.1M |
| access-granted | 1.3.3 | 2021-08-19 | — | ~0.58M |
— [RubyGems API](https://rubygems.org/api/v1/gems/pundit.json) (same endpoint per gem)

**Pundit**
- Policies are plain Ruby classes named `<Model>Policy`, initialized with `(user, record)`, exposing predicate methods like `update?`; `authorize` raises `Pundit::NotAuthorizedError` on denial — [Pundit README](https://github.com/varvet/pundit)
- Scoping: nested `Scope` class with `resolve` returning a relation (e.g. `user.admin? ? scope.all : scope.where(published: true)`), called via `policy_scope(Post)` — [Pundit README](https://github.com/varvet/pundit)
- Verification hooks: `after_action :verify_authorized` raises if `authorize` was not called; `verify_policy_scoped` does the same for `policy_scope`; `skip_authorization` / `skip_policy_scope` to opt out per action — [Pundit README (raw)](https://raw.githubusercontent.com/varvet/pundit/main/README.md)
- Headless policies: `authorize :dashboard, :show?`; namespaced policies `authorize([:admin, post])` → `Admin::PostPolicy` — [Pundit README](https://github.com/varvet/pundit)
- Rails 8 auth generator: README documents defining `pundit_user` to return `Current.user` because the generator uses `Current.user` instead of `current_user`; `pundit_user` can also return a context object, e.g. `UserContext.new(current_user, request.ip)` — [Pundit README (raw)](https://raw.githubusercontent.com/varvet/pundit/main/README.md)
- Strong params: README now documents `expected_attributes_for_action(action_name)` / `expected_attributes(@post)` to feed `params.expect` (Rails 8). Unreleased changelog entry: "Add support for `params.expect` using `expected_parameters` and `expected_parameters_for`" (#855) — [Pundit README](https://raw.githubusercontent.com/varvet/pundit/main/README.md); [Pundit CHANGELOG](https://raw.githubusercontent.com/varvet/pundit/main/CHANGELOG.md). (Older docs used `permitted_attributes`; naming is in flux between README and changelog — verify against the installed version.)
- Caching: Pundit caches policy/scope *instances* per request; 2.5.0 added `pundit_reset!` "to reset the policy and policy scope cache". 2.5.0 also added a Rails 8 auth-generator example and registered policy dirs for Rails 8 code statistics — [Pundit CHANGELOG](https://raw.githubusercontent.com/varvet/pundit/main/CHANGELOG.md)
- Testing: `pundit/rspec` provides `permissions :update?, :edit? do ... expect(subject).to permit(user, record)`; 2.5.0 made `permit` without a `permissions` block raise a useful error — [Pundit README](https://github.com/varvet/pundit); [CHANGELOG](https://raw.githubusercontent.com/varvet/pundit/main/CHANGELOG.md)
- GitHub stars ~8.5k (as reported on repo page) — [Pundit repo](https://github.com/varvet/pundit)

**Action Policy (Evil Martians / palkan)**
- "Authorization framework for Ruby and Rails applications. Composable. Extensible. Performant."; "relies on resource-specific policy classes (just like Pundit)"; `ApplicationPolicy < ActionPolicy::Base`; generators `action_policy:install`, `action_policy:policy Post` — [Action Policy README](https://github.com/palkan/action_policy)
- Origin: Pundit was Evil Martians' choice "for a long time", but being "too dead-simple" it "required a lot of hacking", so they built Action Policy (initially "Pundit, re-visited") — [Action Policy guide](https://actionpolicy.evilmartians.io/guide/) (via search snippet)
- Features: aliases, pre-checks, `authorized_scope` / `relation_scope` scoping, failure reasons, i18n of error messages, instrumentation, RSpec and Minitest matchers — [Action Policy docs](https://actionpolicy.evilmartians.io/)
- Caching layers: rule-level memoization, local (instance-level) memoization, and external cache store — [Action Policy guide](https://actionpolicy.evilmartians.io/guide/) (via search snippet)
- Integrations: `action_policy-graphql`, `action_policy-graphiti`; talks: RailsConf 2018 "Access Denied: the missing guide to authorization in Rails" — [Action Policy README](https://github.com/palkan/action_policy)
- Blog claim: Action Policy computes a repeated check (e.g. `update?` 50 times in a view loop) once per request whereas Pundit recomputes — [norvilis.com](https://norvilis.com/pundit-vs-cancancan-vs-action-policy-which-rails-auth-gem-wins/). Caveat: secondary blog; Pundit does cache the policy instance, it just does not memoize rule results.

**CanCanCan**
- All rules centralized in a single `Ability` class; best when controllers are RESTful and `accessible_by` maps cleanly to data; risk: Ability becomes "a large conditional file" — [Saeloun, 2026-04-28](https://blog.saeloun.com/2026/04/28/rails-authorization-patterns-complete-guide/)
- Pain point: "forced to define all your abilities in a single ability.rb file, which becomes very cumbersome" as app grows — [Alessandro Rodi, "CanCanCan that scales"](https://medium.com/@coorasse/cancancan-that-scales-d4e526fced3d) (Rodi is a CanCanCan maintainer; article proposes splitting abilities)
- Performance: entire ability file evaluated when checking abilities; "a slow query in the ability file can bring the whole site down"; Pundit only checks a single class — [Tom Kadwill, "Is CanCanCan Dead?"](https://medium.com/@tomkadwill/is-cancancan-dead-4b25a43306ad) (older post; author later posted a revision)
- Claims of 2,000-line production ability files — [norvilis.com](https://norvilis.com/pundit-vs-cancancan-vs-action-policy-which-rails-auth-gem-wins/) (anecdotal)

**Rolify**
- Rolify stores role assignments (optionally resource-scoped); it has no policy/check engine and is typically paired with Pundit/CanCanCan. Last release 6.0.1 on 2023-02-02 — [RubyGems API](https://rubygems.org/api/v1/gems/rolify.json). (Characterization of purpose is from the gem's well-known README; not re-fetched this session.)

**Others**
- access-granted: role-based, priority-ordered roles; last release 2021-08-19 (stale) — [RubyGems](https://rubygems.org/api/v1/gems/access-granted.json); [its wiki on role-based authz](https://github.com/chaps-io/access-granted/wiki/Role-based-authorization-in-Rails)
- declarative_policy (GitLab) is published as a standalone gem and released in 2025-2026 (see section 2).

**Consolidated guidance (2026)**
- Saeloun: Pundit = "recommended default", best when "record-level authorization and tenant scoping must be visible in code reviews"; Action Policy when you need "failure reasons, caching for expensive checks, or policy aliases" at the cost of "more framework surface area" — [Saeloun](https://blog.saeloun.com/2026/04/28/rails-authorization-patterns-complete-guide/)
- Pundit vs CanCanCan comparison — [AppSignal, 2023](https://blog.appsignal.com/2023/03/22/authorization-gems-in-ruby-pundit-and-cancancan.html); [Ben Koshy, 2022](https://benkoshy.github.io/2022/02/15/cancancan-or-pundit.html)

### Inferences
- For a JSON API + Vue SPA, Pundit's or Action Policy's `verify_authorized`-style hook is the single most valuable feature: it turns "forgot to authorize" into a test/runtime failure.
- Pundit "boilerplate" (one class per model, repeated `Scope` classes) is the main cost; with only ~9 roles and a flat permission set, most policies would just delegate to a shared `can?(:permission)` check, so boilerplate is the dominant cost of adopting Pundit here.
- Rolify adds a `roles`/`users_roles` join model for a problem that 5+4 fixed roles do not have; not recommended.

### Gaps
- Could not fetch the Evil Martians launch blog post (404 at the URL tried); Action Policy details come from its docs/README.
- No authoritative 2025-2026 usage survey (e.g. Rails Community Survey breakdown for authz gems) found in this session.

## 2. How large Rails apps structure authorization (GitLab, Discourse, Mastodon, Forem, 37signals, Shopify)

### Takeaway
Big apps converge on a central "can user do X on subject Y" API but implement it very differently: GitLab uses its DeclarativePolicy DSL plus YAML-defined permissions/roles; Discourse a hand-rolled Guardian object; Mastodon Pundit-style policies plus a bitmask of role permission flags; Forem Pundit; 37signals no gem at all (role enum + `can_*?` model methods + `before_action :ensure_*` + scoping through `Current.user`/`Current.account` associations).

### Cited Findings

**GitLab — DeclarativePolicy**
- Three concepts: *conditions* (cached facts, e.g. `condition(:owns) { @subject.owner?(@user) }`), *rules* combining them (`rule { owns }.enable :sell_vehicle`, `rule { ~old_enough_to_drive }.prevent :drive_vehicle`); an ability is allowed when at least one rule enables it and none prevents it — [declarative-policy README](https://gitlab.com/gitlab-org/ruby/gems/declarative-policy/-/raw/main/README.md)
- Performance: conditions have a `score:` so expensive ones evaluate later; evaluation short-circuits; results cached across policy calls; policies support inheritance and `delegate` — [declarative-policy README](https://gitlab.com/gitlab-org/ruby/gems/declarative-policy/-/raw/main/README.md)
- Gem released 2.0.1 (2025-08) and 2.1.0 (2026-03-13) — [RubyGems API](https://rubygems.org/api/v1/versions/declarative_policy.json)

**GitLab — custom roles (Ultimate)**
- "Each custom role is based on an existing default role"; Ultimate tier; member roles (group/project, inheritable, consume a seat except Guest with only `read_code`) and admin roles (instance-wide, self-managed/Dedicated); max 10 custom roles per instance/group; base role cannot be changed after creation; cannot delete an assigned role — [GitLab docs: custom roles](https://docs.gitlab.com/user/custom_roles/)
- Implementation: `member_roles` table (`MemberRole` model) tied to top-level groups via `namespace_id`, with `base_access_level` and permission flags; `members.member_role_id` FK links a membership to a custom role — [GitLab dev docs: custom roles](https://docs.gitlab.com/development/permissions/custom_roles/)
- Each custom ability is a YAML file in `ee/config/custom_abilities/` with `name`, `title`, `description`, `feature_category`, `group_ability`/`project_ability`, `group_permissions`/`project_permissions` (lists of underlying policy abilities to enable), optional `requirements`, milestone/MR metadata; `wip: true` hides unfinished abilities behind `GITLAB_LOAD_WIP_CUSTOM_ABILITIES=true` — [GitLab dev docs](https://docs.gitlab.com/development/permissions/custom_roles/)
- At boot GitLab auto-generates `custom_role_enables_<ability>` conditions in `GroupPolicy`/`ProjectPolicy` from the YAML, "without manual code changes" — [GitLab dev docs](https://docs.gitlab.com/development/permissions/custom_roles/)
- Concrete example `read_vulnerability.yml`: `enabled_for_group_access_levels: [25, 30, 40, 50]`, `group_permissions: [create_vulnerability_export, read_group_security_dashboard, read_security_resource, read_vulnerability, read_vulnerability_statistics]`, plus ~10 `project_permissions`; milestone 16.1 — [GitLab source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/ee/config/custom_abilities/read_vulnerability.yml)
- As of 2026-09 there are ~39 custom ability YAMLs (e.g. `admin_merge_request`, `admin_cicd_variables`, `manage_deploy_tokens`, `read_code`, `remove_project`) plus a `type_schema.json` — [GitLab API tree listing](https://gitlab.com/api/v4/projects/278964/repository/tree?path=ee/config/custom_abilities&per_page=100)
- Newer: GitLab now also declares the *default* roles as data: `config/authz/roles/*.yml` (17 files: guest, planner, reporter, developer, maintainer, owner, auditor, security_manager, etc.), e.g. `developer.yml` has `inherits_from: [reporter]` and a `project.raw_permissions` list (`admin_merge_request`, `approve_merge_request`, `create_build`, ...); also `config/authz/permissions/` (100+ permission dirs) and `permission_groups/` — [GitLab developer.yml](https://gitlab.com/gitlab-org/gitlab/-/raw/master/config/authz/roles/developer.yml); [tree listing](https://gitlab.com/api/v4/projects/278964/repository/tree?path=config/authz&per_page=100)

**Discourse — Guardian**
- A single `Guardian` object composed of modules (`BookmarkGuardian`, `CategoryGuardian`, `PostGuardian`, `TopicGuardian`, `UserGuardian`); `can_see?(obj)` dynamically dispatches to `can_see_<class>?` (e.g. `can_see_topic?`); `can_edit?`/`can_delete?` go through `can_do?`, returning false for anonymous; an `AnonymousUser` null object handles logged-out users — [discourse/lib/guardian.rb](https://github.com/discourse/discourse/blob/main/lib/guardian.rb)
- (Discourse controllers use `guardian.ensure_can_*!` which raises `Discourse::InvalidAccess`; the fetch confirmed the pattern is referenced but the raising code lives elsewhere — not independently verified this session.)

**Mastodon — Pundit-style policies + bitmask role flags**
- `StatusPolicy < ApplicationPolicy` with `show?`, `reblog?`, `favourite?`, `destroy?`, `update?`, built from private predicates (`owned?`, `blocking_author?`, `following_author?`, `mention_exists?`) — [mastodon status_policy.rb](https://github.com/mastodon/mastodon/blob/main/app/policies/status_policy.rb)
- Admin permissions: `UserRole::FLAGS` is a frozen hash of ~23 permission flags as powers of two (`administrator: 1<<0`, `view_devops: 1<<1`, `view_audit_log: 1<<2`, ..., `manage_reports`, `manage_users`, `manage_roles`, `manage_webhooks`, `invite_users`), stored in a bigint `permissions` column on `user_roles`; `can?(*any_of_privileges)` does a bitwise check; `administrator` grants everything — [mastodon user_role.rb](https://github.com/mastodon/mastodon/blob/main/app/models/user_role.rb)

**Forem (dev.to)**
- Uses Pundit; `ApplicationPolicy` delegates role checks to the user (`support_admin?`, `super_moderator?`, `super_admin?`, `any_admin?`, `suspended?`), defines `UserSuspendedError`/`UserRequiredError`, `require_user_in_good_standing!`; default actions deny unless overridden; comments discourage `if user.admin?` in views/controllers — [forem application_policy.rb](https://github.com/forem/forem/blob/main/app/policies/application_policy.rb)

**37signals (Campfire, Fizzy) — no gem**
- Campfire: `User::Role` concern: `enum :role, %i[ member administrator bot ]`; `def can_administer?(record = nil) = administrator? || self == record&.creator || record&.new_record?`; controller concern `Authorization#ensure_can_administer` → `head :forbidden unless Current.user.can_administer?`; records loaded via `Current.user.memberships.find_by!(room_id: ...)` — [basecamp/once-campfire](https://github.com/basecamp/once-campfire) (`app/models/user/role.rb`, `app/controllers/concerns/authorization.rb`, `room_scoped.rb`)
- Fizzy (multi-account SaaS): `enum :role, %i[ owner admin member system ]`; `admin?` overridden to include owner; model predicates `can_change?(other)`, `can_administer?(other)`, `can_administer_board?(board)`, `can_administer_card?(card)`; `Authorization` concern has a global `before_action :ensure_can_access_account` (account active + user active) with `allow_unauthorized_access` class macro to skip, plus `ensure_admin`, `ensure_staff`; controllers do `before_action :ensure_permission_to_admin_board, only: %i[update destroy]` — [basecamp/fizzy](https://github.com/basecamp/fizzy) (`app/models/user/role.rb`, `app/controllers/concerns/authorization.rb`, `boards_controller.rb`)
- Fizzy tenant scoping: `Current` has `attribute :session, :user, :identity, :account`; lookups go through associations: `Current.user.boards.find params[:id]`, `Current.user.accessible_cards.find_by!(number: ...)`, `Current.account.users.find(params[:user_id])`; ~35 models `belong_to :account` — [basecamp/fizzy](https://github.com/basecamp/fizzy) (`app/models/current.rb`, `cards_controller.rb`, `users/data_exports_controller.rb`)

**Shopify**
- No public source found describing Shopify core's authorization internals in this session.

### Inferences
- The two "data-driven role" examples (GitLab `config/authz/roles/*.yml` with `inherits_from` + permission lists; Mastodon's frozen `FLAGS` hash) are close analogues of a "frozen role→permissions map". GitLab layered custom roles by keeping the fixed-role mapping and adding a DB `member_roles` row that *adds* named abilities to a base role — a migration path worth preserving (name permissions as stable symbols from day one).
- 37signals shows a gem-free design is viable in production SaaS when (a) every lookup is scoped through `Current.*` associations and (b) the permission surface is small. It does not have an automatic "did you authorize?" guard; safety relies on convention plus the account-level `before_action`.

### Gaps
- Did not verify Discourse `ensure_can_*!` source lines directly.
- Shopify: nothing public and authoritative found.
- GitLab `config/authz/README` 404'd; the exact runtime wiring of `config/authz/roles` into policies was not confirmed.

## 3. Multi-tenant scoping: association scoping vs acts_as_tenant vs default_scope vs Postgres RLS

### Takeaway
Scoping every lookup through the tenant (`current_account.invoices.find(id)` or `policy_scope(Invoice).find(id)`) is the baseline and converts cross-tenant IDs into 404s. acts_as_tenant automates that with a default scope plus validation (v2.0.0, Sep 2026, fixed cross-tenant assignment holes). Postgres RLS is the strongest backstop but has sharp operational pitfalls (pooling, superuser/owner bypass, indexes).

### Cited Findings
- "Scope before finding records": `Invoice.find(params[:id]); authorize @invoice` "can leak whether a record exists"; `policy_scope(Invoice).find(params[:id])` "treats cross-tenant access as not found" — [Saeloun](https://blog.saeloun.com/2026/04/28/rails-authorization-patterns-complete-guide/)
- Pitfalls listed: checking `update?` on one record is not enough if "index pages, exports, APIs, or background jobs can read from other accounts"; view checks "are for hiding buttons, not for protecting the endpoint"; "Re-check authorization in jobs when permissions can change after enqueue"; test cross-account access, not only happy paths — [Saeloun](https://blog.saeloun.com/2026/04/28/rails-authorization-patterns-complete-guide/)
- 37signals Fizzy uses association scoping via `Current.user`/`Current.account` rather than a tenant gem or default_scope — [basecamp/fizzy](https://github.com/basecamp/fizzy)
- acts_as_tenant 2.0.0 (released 2026-09-21): security fix — models with polymorphic tenants could create records for another tenant while a tenant was set; records assigned to a tenant other than current now fail validation. Breaking: with no tenant set, a `belongs_to` to a record from a different tenant fails validation (affects admin tools, scripts, factories); `belongs_to` declared after `acts_as_tenant` validated against current tenant — [acts_as_tenant releases](https://github.com/ErwinM/acts_as_tenant/releases); [RubyGems](https://rubygems.org/api/v1/versions/acts_as_tenant.json)
- RLS pitfalls: never use `SET` (session-scoped; leaks previous tenant through pooled connections) — use `SET LOCAL` / `set_config(..., true)` inside a transaction; BEGIN, set_config, and all tenant queries must be on the same physical connection — [DEV: RLS for multi-tenant SaaS](https://dev.to/software_mvp-factory/postgresql-row-level-security-for-multi-tenant-saas-1lgp); [patotski.com](https://patotski.com/blog/postgres-row-level-security-multi-tenant/)
- RLS: owners and superusers bypass RLS by default — connect as a dedicated non-owner, non-superuser role; don't grant `BYPASSRLS` to admin roles, use an explicit admin policy; with no tenant context, queries match zero rows (secure by default); missing composite indexes with `tenant_id` leading make RLS "two orders of magnitude slower" — [search synthesis of DEV/rivestack/queryplane](https://queryplane.com/blog/postgres-row-level-security-in-practice/); [pganalyze on RLS in Rails](https://pganalyze.com/blog/postgres-row-level-security-ruby-rails); [DEV: two traps that silently disable policies](https://dev.to/wenceslaudev/postgres-rls-multi-tenancy-two-traps-that-silently-disable-your-policies-5gn8)

### Inferences
- IDOR prevention ranking (strongest → weakest): RLS as defense-in-depth (DB enforces even if app code forgets) > acts_as_tenant (automatic default scope + validation, but bypassable by `unscoped`, `ActsAsTenant.without_tenant`, raw SQL, and relies on the current tenant being set correctly in jobs) > disciplined association scoping (`Current.merchant.payments.find`) enforced by a lint/test > `Model.find` + per-record policy check (correct but leaks existence and easy to forget on index/export endpoints).
- For a payments app with a platform-operator side (operators see across merchants), a global default scope fights the operator use case; explicit scoping via policy scopes (`merchant user → merchant's rows; operator → all or assigned`) maps more cleanly. RLS would need a separate operator policy/role, adding operational complexity.
- Background jobs are a common hole: pass `merchant_id` explicitly and re-scope inside the job.

### Gaps
- No quantitative data on which approach correlates with fewer IDOR incidents in Rails apps; ranking above is reasoning, not measured.

## 4. Is a frozen role→permissions hash + `authorize!` concern reasonable vs a gem?

### Takeaway
Yes for a small, fixed role set — and it has direct precedents (Mastodon's frozen `FLAGS` hash, GitLab's role YAMLs, 37signals' gem-free `ensure_*` concerns). The known risks are (1) no automatic "forgot to authorize" guard and (2) it covers role-level ("can merchant_viewer read refunds?") but not record-level/tenant rules. Mitigate by adding your own `after_action :verify_authorized` equivalent and routing all record lookups through scopes; or use Pundit/Action Policy with the hash as the permission source.

### Cited Findings
- "This is fine when the app has a few roles and no record-level rules"; it "breaks down" with tenant dependencies, ownership rules, workflow states, or feature flags — [Saeloun](https://blog.saeloun.com/2026/04/28/rails-authorization-patterns-complete-guide/)
- "You don't need a gem, especially if your application is small"; plain-Ruby policy objects are straightforward to build — [Honeybadger](https://www.honeybadger.io/blog/complete-guide-to-managing-user-permissions-in-rails-apps/)
- Precedent — Mastodon: frozen `FLAGS` hash + `can?(*privileges)` on the role — [mastodon user_role.rb](https://github.com/mastodon/mastodon/blob/main/app/models/user_role.rb)
- Precedent — GitLab: roles declared as data files mapping role → permission list with `inherits_from` — [GitLab developer.yml](https://gitlab.com/gitlab-org/gitlab/-/raw/master/config/authz/roles/developer.yml)
- Precedent — 37signals: `enum :role` + `can_*?` predicates + `before_action :ensure_*` returning `head :forbidden`; a global account-access `before_action` with an explicit opt-out macro (`allow_unauthorized_access`) — [basecamp/fizzy](https://github.com/basecamp/fizzy); [basecamp/once-campfire](https://github.com/basecamp/once-campfire)
- Pundit's own verification design (`verify_authorized` raising if `authorize` was never called, `skip_authorization` to opt out) is the pattern a hand-rolled concern should replicate — [Pundit README](https://raw.githubusercontent.com/varvet/pundit/main/README.md)
- Pundit supports "headless" policies (`authorize :dashboard, :show?`), so a permission-based hash can sit behind Pundit without per-model record logic — [Pundit README](https://github.com/varvet/pundit)

### Inferences
- For 5 fixed merchant roles + 4 operator roles, a reasonable design is: `PERMISSIONS = { merchant_owner: %i[...], ... }.freeze` (permission symbols, not role checks, in controllers) + a controller concern `authorize!(:refunds_create)` + a fail-closed `after_action` that raises if no `authorize!`/`skip_authorization!` ran + tenant scoping through `Current.merchant` associations (or a small scope helper). Expose the effective permission list to the Vue app via a `/me` endpoint so UI hiding uses the same source (UI is cosmetic; API is enforcement).
- Choosing Pundit instead buys the verify hooks, `policy_scope`, and RSpec matchers for free at the cost of one class per resource; Action Policy additionally buys scope matchers (`have_authorized_scope`) and per-request caching, which matter little at this scale. Either can consume the same frozen hash, so the hash decision and the gem decision are independent.
- Name permissions as stable `resource_action` symbols now; GitLab's path shows that adding DB-defined custom roles later is simply "base role + extra named permissions", which only works if permissions (not role names) are checked at call sites.

### Gaps
- Found no well-known named Rails expert essay (e.g. from 37signals' dev blog) explicitly arguing "hash + concern over Pundit"; the 37signals evidence is from their code, not prose.
- No RailsConf 2023-2026 authorization talk located in this session (newest cited talk: RailsConf 2018 "Access Denied" by Vladimir Dementyev).
