# Permission and Role Models at Large SaaS and Cloud Platforms

Scope: permission naming schemes, where the role-to-permission map lives, the path from fixed roles to custom roles, and vendor best practices and anti-patterns. Sources were fetched in September 2026. Documented platform behaviour is kept apart from vendor opinion: items marked **[vendor opinion]** come from companies that sell authorization products.

## 1. What permission naming schemes do major platforms use, and how do they handle wildcards, hierarchies, and grouping?

### Takeaway
Every major platform names a permission as a **resource-type plus an action (verb)**, namespaced by service. AWS uses `service:Action`, GCP `service.resource.verb`, Azure `Company.Provider/resourceType/action`, and Stripe and GitHub use a resource with a None/Read/Write level. Roles are named bundles of these strings. Wildcards and "write implies read" handle grouping, and in AWS and Azure a wildcard grants actions added in the future.

### Cited Findings
**AWS IAM**
- Actions use a service namespace prefix followed by the action name, e.g. `sqs:SendMessage`, `ec2:StartInstances`, `s3:GetObject`. "The prefix and the action name are case insensitive", so `iam:ListAccessKeys` is the same as `IAM:listaccesskeys`. — [AWS IAM Action element](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_action.html)
- Wildcards `*` (multi-character) and `?` (single-character) are allowed for a whole service (`s3:*`) or part of a name (`iam:*AccessKey*` matches Create/Delete/List/UpdateAccessKey). Statements take either `Action` or `NotAction`. — [AWS IAM Action element](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_action.html)
- AWS publishes machine-readable JSON "service reference information" listing the actions, resources, and condition keys for each service, for policy automation. — [AWS IAM Action element](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_action.html)

**Google Cloud IAM**
- Permissions follow `SERVICE.RESOURCE.VERB`, e.g. `compute.instances.list` and `compute.instances.stop`. — [GCP Roles overview](https://docs.cloud.google.com/iam/docs/roles-overview)
- There are three kinds of role:
  - **Basic** roles: Reader, Writer, Admin, plus the legacy Owner, Editor, Viewer. Google's guidance is "do not grant basic roles unless there is no alternative."
  - **Predefined** roles: Google maintains them and "automatically updates their permissions as necessary."
  - **Custom** roles: bundles the user defines, which do not update automatically.
  — [GCP Roles overview](https://docs.cloud.google.com/iam/docs/roles-overview)
- Permissions have "permission dependencies": some need companion permissions before they work. — [GCP Roles overview](https://docs.cloud.google.com/iam/docs/roles-overview)

**Azure RBAC**
- Action strings take the form `{Company}.{ProviderName}/{resourceType}/{action}`, e.g. `Microsoft.Storage/storageAccounts/blobServices/containers/read`. The action part maps to HTTP semantics: `read` for GET, `write` for PUT/PATCH, `delete` for DELETE, and `action` for custom POST operations such as restarting a VM. — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
- Wildcards can appear at any level: `*/read`, `Microsoft.Compute/*`, `Microsoft.Network/*/read`, `Microsoft.Compute/virtualMachines/*`. The built-in Contributor role has `Actions: ["*"]`, which "includes actions defined in the future, as Azure adds new resource types." — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
- `NotActions` subtracts from a wildcard: "Actions - NotActions = Effective control plane permissions." It "is not a deny rule". If a second role grants the excluded action, the user can perform it. Real denies are a separate construct called deny assignments. — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
- Control-plane (`Actions`) and data-plane (`DataActions`) permissions are kept apart. Azure added the data properties so that existing role assignments with wildcards (`*`) would not "suddenly" gain access to data. This is an explicit example of evolving a permission schema without widening existing grants. — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
- Role definitions are identified by an immutable GUID. "Built-in roles have the same role ID across clouds", and "Even if the role is renamed, the role ID does not change. It's a best practice to use the role ID in your scripts." — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
- Azure marks a role as "privileged" if it contains `*`, `*/write`, `*/delete`, or writes to `Microsoft.Authorization/roleAssignments` or `roleDefinitions`. In other words, the power to manage roles is itself a permission. — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)

**Stripe**
- Each restricted API key (`rk_live_` / `rk_test_`) gives every resource one of **None**, **Read**, or **Write**. The default is None. "Write permissions imply read permissions: any key that can write an API resource can also read that resource." GET maps to read, and POST/DELETE map to write. Permissions are "grouped into categories", such as Billing. — [Stripe restricted API keys](https://docs.stripe.com/keys/restricted-api-keys)
- Stripe states its reason: least privilege and a smaller blast radius if a key leaks. A key that can only read disputes "couldn't create charges, access customer payment methods, or trigger payouts." — [Stripe restricted API keys](https://docs.stripe.com/keys/restricted-api-keys)
- Dashboard users get fixed, job-function roles, each with a stable machine ID used for SSO mapping, e.g. `admin`, `iam_admin`, `super_admin`, `developer`, `analyst`, `dispute_analyst`, `refund_analyst`, `view_only`, `support_specialist`, `transfer_analyst`. "If you assign a user multiple roles, they're assigned all the permissions of each individual role." — [Stripe user roles](https://docs.stripe.com/get-started/account/teams/roles)
- Stripe keeps access management apart from business power. `IAM Administrator` "can't do anything beyond access management" and cannot assign Administrator or Super Administrator. Only a Super Administrator can grant Super Administrator. — [Stripe user roles](https://docs.stripe.com/get-started/account/teams/roles)

**GitHub**
- Permissions for fine-grained personal access tokens and GitHub Apps are named by resource ("Contents", "Issues", "Pull requests", "Actions", "Secrets", "Members", "Administration", "Webhooks") with a read or write level. They are grouped into Repository, Organization, and User (account) categories. — [GitHub fine-grained PAT permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)
- Repository roles form a hierarchy: Read < Triage < Write < Maintain < Admin. Each has a stated persona, e.g. Maintain is for "Project managers who need to manage the repository without access to sensitive or destructive actions". Access is cumulative: "the user has the sum of all access grants." — [GitHub custom repository roles](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/about-custom-repository-roles)

**Authorization vendors [vendor opinion]**
- WorkOS recommends separating resource and action with a delimiter, e.g. `users:view` (allowed delimiters `-.:_*`). It advises keeping slugs short because the permission slugs are included in session JWT claims, and cookies are often limited to about 4KB. — [WorkOS RBAC configuration (search summary)](https://workos.com/docs/rbac/configuration)
- Oso recommends an action-on-resource-type convention: "if a user has that permission, they can perform 'action' on a resource of type 'resource.'" Its custom-roles example uses dotted strings such as `repository.read`. — [Oso Academy: RBAC](https://www.osohq.com/academy/what-is-rbac); [Oso custom roles](https://www.osohq.com/docs/develop/policies/patterns/custom-roles)

### Inferences
- Across platforms, the stable, documented unit is the **permission string**, and roles are bundles of those strings. The delimiter varies (`:`, `.`, `/`) but the grammar is always namespace, then resource, then verb. The reasons are consistent: permissions map one-to-one to API operations (Azure maps to HTTP verbs, Stripe maps GET to read), so they can be enumerated, audited, and assigned least-privilege.
- Wildcards are a double-edged tool. Azure and AWS wildcards silently include future actions. That is convenient for admin roles and dangerous for anything else. Azure's DataActions split shows the fix is to put sensitive new permissions in a namespace that existing wildcards do not match.
- "Write implies read" is explicit at Stripe. Azure and AWS model it through bundles rather than implication. GitHub models it through an ordered role hierarchy.

### Gaps
- GitHub's docs do not say explicitly whether write implies read for fine-grained PAT permissions. The fetched summary found no such statement.
- I did not fetch Auth0, Okta, or Permit.io permission-string documentation. By common practice Auth0 API permissions use a `read:messages` (verb:resource) style, but this was not verified in this session.
- Slack, Figma, Notion, Carta, Segment, and Netflix authorization posts were not retrieved within the time budget.

## 2. Where is the role-to-permission map stored (code, config/YAML, or database)? When does it move to the DB, and what problems appear?

### Takeaway
Fixed or built-in roles live in code, policy, or config, which the vendor ships and versions. Custom roles are tenant-owned data in a database. The move happens when customers must author roles. The cost is permission drift (custom roles don't pick up new permissions), exposing the permission catalogue as a public contract, ID and lifecycle rules, and role explosion.

### Cited Findings
- **[vendor opinion]** Oso: for standard roles, "a simple dictionary from role name to a string list of permissions" in code is enough. For custom roles "the map from a role to a list of permissions needs to be dynamic, and we need a way to associate users with dynamically created role[s]". — [Oso Academy: RBAC](https://www.osohq.com/academy/what-is-rbac)
- Oso's product pattern: built-in roles are declared in policy (`roles = ["admin", "member"]`). For a custom role, "Oso stores its metadata and unique ID in the application database", and its permissions are data facts, e.g. `grants_permission(Role{"repo-admin"}, "repository.read")`. The policy declares the permission vocabulary, and custom roles may only reference that vocabulary. — [Oso custom roles](https://www.osohq.com/docs/develop/policies/patterns/custom-roles)
- Oso advises separating "Low-level actions your application enforces via oso.authorize calls" from "Higher-level, user-facing permissions that can be assigned to roles." This avoids exposing implementation details through role configuration. — [Oso custom roles](https://www.osohq.com/docs/develop/policies/patterns/custom-roles)
- **[vendor opinion]** Oso strongly discourages custom roles for most applications. Their reason: "you need to be comfortable making your definitions of permissions public... Adding new features with new permissions or reorganizing parts of your application can have unintended consequences if those permissions are exposed in user-configured roles." Oso suggests custom roles only for "applications that need deep configurability, such as platforms-as-a-service", and points to GitHub's and GitLab's long delays in shipping them. — [Oso Academy: RBAC](https://www.osohq.com/academy/what-is-rbac); [Oso custom roles search summary](https://www.osohq.com/docs/develop/policies/patterns/custom-roles)
- **Drift (documented):** GCP custom roles are not updated automatically. "You are responsible for maintaining custom roles. This includes... updating roles to let users access new features that require additional permissions." Predefined roles, by contrast, are updated by Google. — [GCP understanding custom roles](https://docs.cloud.google.com/iam/docs/understanding-custom-roles)
- GCP gives each permission a custom-role support level: `SUPPORTED`, `TESTING`, or `NOT_SUPPORTED`. Not every internal permission is exposed to customer-built roles. — [GCP understanding custom roles](https://docs.cloud.google.com/iam/docs/understanding-custom-roles)
- **Lifecycle and ID rules (documented):**
  - GCP custom roles carry launch stages (`ALPHA`, `BETA`, `GA`, `DISABLED`). A disabled role still appears in policies but has no effect.
  - Role IDs cannot be reused until a 44-day deletion process finishes.
  - Basic and predefined roles always have ETag `AA==`, while custom-role ETags change on every edit, which gives optimistic concurrency.
  — [GCP understanding custom roles](https://docs.cloud.google.com/iam/docs/understanding-custom-roles); [GCP Roles overview](https://docs.cloud.google.com/iam/docs/roles-overview)
- **Limits (documented):**
  - GCP: 300 custom roles per organization and 300 per project. — [GCP Roles overview](https://docs.cloud.google.com/iam/docs/roles-overview)
  - Azure: 5,000 custom roles per tenant. Azure advises against scoping a custom role to one resource instance because it "could potentially exhaust your available custom roles". Define the role broadly and assign it narrowly. — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
  - GitHub Enterprise Cloud: up to 20 custom repository roles; earlier GHES versions allowed 5. — [GitHub custom repository roles](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/about-custom-repository-roles)
- **Role explosion [vendor opinion]:** Cerbos describes "the dreaded 'role explosion' anti-pattern", where tenant-specific variants (`Editor_TenantA`, `Editor_TenantB`…) lead to "10,000 role definitions to manage – one set of 10 roles per tenant". Its fix is tenant-scoped role assignment, where "a user's permissions are always evaluated in the context of a specific tenant". — [Cerbos multitenant authorization](https://www.cerbos.dev/blog/how-to-implement-scalable-multitenant-authorization)
- Cerbos recommends policy-as-code: "a declarative policy language or configuration, store them in a version control system like Git". Cerbos policies are YAML. — [Cerbos multitenant authorization](https://www.cerbos.dev/blog/how-to-implement-scalable-multitenant-authorization)
- Airbnb's Himeji, a Zanzibar-based system, centralizes authorization data and checks. It stores "tens of billions of relations", serves close to a million entity checks per second at 99.999% availability and 12ms p99, and fans out on writes rather than reads. — [Airbnb Himeji blog (search summary; direct fetch returned 403)](https://medium.com/airbnb-engineering/himeji-a-scalable-centralized-system-for-authorization-at-airbnb-341664924574)

### Inferences
- The industry pattern is a **hybrid**. The permission vocabulary, and usually the built-in roles, live in code or config and ship with deploys. Custom roles are rows in a database that reference permission strings. The database never invents permissions; it only combines them.
- Drift is the main cost of custom roles. When you ship a feature with a new permission, built-in roles pick it up in the release but custom roles don't. Platforms either accept this (GCP makes it the customer's job) or avoid it by having custom roles *inherit* a built-in base role (GitHub, section 3).
- Hard limits on custom roles (GCP 300, Azure 5,000, GitHub 20) are a deliberate brake on role explosion and on the cost of evaluating policy.

### Gaps
- I found no primary engineering blog post (GitHub, Stripe, Slack, Figma, Notion, Carta) that describes a concrete code-to-DB migration of the role map, including schema or data-migration steps. The Himeji post could not be fetched directly (403), so its motivation and config format are unverified here.
- I found no published data on how often permission drift causes incidents.

## 3. How do platforms move from fixed roles to custom roles without breaking existing users?

### Takeaway
The documented patterns are:
- Keep the existing fixed roles as **immutable built-in roles with stable IDs**.
- Make custom roles **layer on top of** a built-in base role (GitHub), or be **copied from** a predefined role as a template (GCP).
- Grow the permission catalogue step by step.
- Add new, sensitive permission classes in a way that existing wildcard grants don't pick up (Azure DataActions).
- Keep shipping new *predefined* roles so customers aren't forced into custom roles.

### Cited Findings
- **GitHub, inherit a base role:** a custom repository role starts from a base role (Read, Triage, Write, or Maintain), and "you can layer on additional permissions not already included in that inherited role." Examples: manage webhooks, push to protected branches, manage Dependabot/code-scanning alerts, manage runners, secrets, and environments. — [GitHub custom repository roles](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/about-custom-repository-roles)
- **GitHub timeline, an incremental catalogue:**
  - October 2021: custom repository roles for Enterprise. — [GitHub changelog 2021-10-27](https://github.blog/changelog/2021-10-27-enterprise-organizations-can-now-create-custom-repository-roles/)
  - November 2023: custom organization roles GA with about 10 permissions (e.g. "Manage organization webhooks", "View the organization audit logs"). GitHub said "More organization permissions will be built over time, similar to how repository permissions were added." "Roles can be assigned by an organization owner only, to prevent accidental escalation of privileges." — [GitHub changelog 2023-11-16](https://github.blog/changelog/2023-11-16-custom-organization-roles-are-now-ga/)
  - March 2024: Actions fine-grained permissions added to custom org roles. — [GitHub changelog 2024-03-06](https://github.blog/changelog/2024-03-06-actions-fine-grained-permissions/)
  - September 2024: a new *pre-defined* "CI/CD Admin" org role, so owners can delegate "without the need to maintain a custom role". — [GitHub changelog 2024-09-25](https://github.blog/changelog/2024-09-25-introducing-ci-cd-admin-a-new-pre-defined-organization-role-for-github-actions/)
  - June 2025: Actions permissions GA for custom repository roles. — [GitHub changelog 2025-06-26](https://github.blog/changelog/2025-06-26-github-actions-fine-grain-permissions-are-now-generally-available-for-custom-repository-roles/)
- **GCP, predefined roles as templates:** "create custom roles based on predefined roles with similar permissions. Predefined roles are designed with specific tasks in mind and contain all of the permissions you need." Predefined roles are Google-managed, update automatically, and have a fixed ETag (`AA==`), so in practice they are immutable. — [GCP understanding custom roles](https://docs.cloud.google.com/iam/docs/understanding-custom-roles)
- **Azure, built-in roles as data with stable GUIDs:** built-in roles are role-definition objects like custom ones. They are flagged `roleType: BuiltInRole`, use the same GUID in every cloud, and have AssignableScopes `/`. Custom roles use the same schema with `IsCustom: true`. Azure evolved its schema by adding `DataActions` so that existing `*` grants would not suddenly reach data. — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
- **Stripe:** Dashboard roles today are a fixed catalogue of about 25 job-function roles with stable IDs (e.g. `refund_analyst`, `dispute_analyst`). Stripe grows this list by adding narrow built-in roles instead of offering user-defined roles; the current roles doc page shows no custom-role builder. A third-party guide also says "no custom roles or granular permission toggles" exist in the standard Dashboard. Custom-built permissions exist only for API keys (RAK per-resource None/Read/Write), and RAKs are "drop-in replacements for secret API keys", which is a non-breaking migration path. — [Stripe user roles](https://docs.stripe.com/get-started/account/teams/roles); [Stitchflow Stripe guide](https://www.stitchflow.com/user-management/stripe/manual); [Stripe restricted API keys](https://docs.stripe.com/keys/restricted-api-keys)
- **Stripe RAK migration playbook (documented):**
  1. Create an empty RAK in a sandbox.
  2. Derive the needed permissions from the secret key's request logs (GET to read, POST/DELETE to write), or from SDK calls in code.
  3. Watch for 403s and add what's missing.
  4. Create the live key.
  5. Retire the secret key, with an optional delayed expiry of up to 7 days.

  Error responses name the missing permission. — [Stripe restricted API keys](https://docs.stripe.com/keys/restricted-api-keys)

### Inferences
- A common recipe emerges:
  1. Turn existing fixed roles into built-in role *records* with stable IDs that tenants cannot edit.
  2. Express them purely as bundles of permission strings.
  3. Switch enforcement from role checks to permission checks. Behaviour stays the same because each built-in role expands to the permissions it effectively had before.
  4. Only then let tenants create roles, either by cloning a built-in (the GCP template approach) or by inheriting one and adding to it (the GitHub approach). Inheriting means custom roles automatically gain new permissions added to the base role, which reduces drift.
- Permission strings become a public API once customers can compose them. Renaming or splitting a permission then needs a migration of every custom role, which is why platforms add permissions far more often than they change them.

### Gaps
- Stripe's "New roles and permissions in the Dashboard" blog post appeared in search but was not fetched. Whether Stripe now offers Dashboard custom roles to some tiers was not verified, and the current roles doc shows none.
- I found no primary source describing GitHub's internal data migration: how the legacy Read/Write/Admin roles were re-expressed as permission bundles in storage.

## 4. What do identity vendors recommend, and what are the common anti-patterns?

### Takeaway
Vendors agree on these points:
- Check **permissions, not role names**, in application code.
- Define roles by job function.
- Use hierarchy or inheritance to stay DRY, but limit it to avoid privilege creep.
- Scope roles to a tenant instead of minting per-tenant role variants.
- Externalize policy into versioned config or a policy engine.
- Treat custom roles as an expensive, late-stage feature.

The main anti-patterns are `if role == "admin"` checks scattered through code, role explosion, and privilege creep.

### Cited Findings
- **[vendor opinion]** WorkOS: "You will run your authorization checks against permissions, not roles", e.g. check `reports:read`, not a role name. Other WorkOS guidance:
  - "Create roles based on actual job functions or responsibilities, not just titles."
  - Use inheritance, e.g. "A Manager role might inherit permissions of the Employee role."
  - "Limit role inheritance to avoid privilege creep."
  - "Assign the fewest roles necessary."
  - Enforce separation of duties.
  - "Conduct regular access audits."
  - Beware role explosion: start with "a straightforward, flexible design."
  — [WorkOS RBAC best practices](https://workos.com/blog/rbac-best-practices)
- **[vendor opinion]** Cerbos names these anti-patterns:
  - "Brittle, hard-coded logic", e.g. "if role == 'Editor_TenantA' or role == 'Admin_TenantA', etc., scattered in various services."
  - Role explosion from per-tenant roles.

  Recommendations: tenant-aware roles, ABAC for contextual rules, policy-as-code in Git, and "Externalize authorization into a dedicated service or component often called a Policy Decision Point." — [Cerbos multitenant authorization](https://www.cerbos.dev/blog/how-to-implement-scalable-multitenant-authorization)
- **[vendor opinion]** Oso recommends a declarative role-to-permission map, a resource-and-action naming convention, a split between enforced low-level actions and user-assignable high-level permissions, and caution about custom roles. — [Oso Academy: RBAC](https://www.osohq.com/academy/what-is-rbac); [Oso custom roles](https://www.osohq.com/docs/develop/policies/patterns/custom-roles)
- **Documented platform practice that matches these recommendations:**
  - Azure: reference roles by immutable ID, not name. It also treats role-management permissions as privileged. — [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
  - GCP: avoid broad basic roles in production. — [GCP Roles overview](https://docs.cloud.google.com/iam/docs/roles-overview)
  - Stripe and GitHub: stop privilege escalation by limiting who can assign powerful roles. At Stripe, only a Super Admin can assign Super Admin, and an IAM Admin cannot assign Admin. At GitHub, only owners can assign org roles. — [Stripe user roles](https://docs.stripe.com/get-started/account/teams/roles); [GitHub changelog 2023-11-16](https://github.blog/changelog/2023-11-16-custom-organization-roles-are-now-ga/)
  - Stripe: one restricted key per service, to limit blast radius. — [Stripe restricted API keys](https://docs.stripe.com/keys/restricted-api-keys)
- **Additive semantics are the documented default.** Multiple roles are unioned at Stripe ("assigned all the permissions of each individual role. Be cautious of conflicts and unintended authority"), at GitHub ("sum of all access grants"), and in Azure, where NotActions is not a deny. — [Stripe user roles](https://docs.stripe.com/get-started/account/teams/roles); [GitHub custom repository roles](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/about-custom-repository-roles); [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)

### Inferences
- Checking permissions rather than roles is what makes custom roles possible later. If code checks `payments:refund` and never `role == admin`, then moving role definitions from code to a database needs no changes at call sites.
- Allow-only, additive models (with a separate, explicit deny mechanism if any) are the norm. Mixing subtractive rules into roles (NotActions) is a convenience for writing roles, not a security boundary.
- Treat "manage roles" and "assign roles" as privileged permissions, and forbid assigning a role more powerful than your own. Stripe, GitHub, and Azure all do this.

### Gaps
- I did not retrieve Permit.io, Aserto, Auth0, or Okta best-practice pages directly. The Cerbos and Permit.io search summary mentioned Permit.io only as a product description.
- Vendor claims are opinion and marketing-adjacent. I found no independent empirical study comparing RBAC maintainability outcomes.
