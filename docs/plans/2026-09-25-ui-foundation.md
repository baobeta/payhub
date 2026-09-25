# PayHub UI Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Lay every foundation the merchant, operator and demo UIs need: the permission catalogue and fail-closed authorization, the audit log, PSP call recording, multi-key API auth with test-mode twin merchants, a Vite Ruby + Vue shell with three entrypoints, and local email through MailCatcher. No user-facing pages yet.

**Architecture:** Rails stays one app. The `/v1` API keeps `ActionController::API` and Bearer keys; only key lookup moves to a new `api_keys` table. New UI controllers inherit `Web::BaseController < ActionController::Base`, which includes an `Authorization` concern driven by a frozen `Permissions` catalogue. Vite Ruby serves three separate Vue bundles (`merchant`, `ops`, `demo`) from three shell pages.

**Tech Stack:** Rails 8.1, Postgres 16 (`structure.sql`), Sorbet, RSpec + FactoryBot, vite_rails 3, Vue 3 + TypeScript, Vitest, ESLint, MailCatcher.

**Design sources:** [UI design](2026-09-25-ui-design.md) (sections 1–3), [use cases](2026-09-25-ui-use-cases.md), `reports/RBAC implementation patterns.md`.

**Scope of this plan:** Phase 0 of the design's build order. Phases 1–3 each get their own plan once this one is merged, because their code depends on what lands here. They are outlined at the end.

---

## Conventions for whoever executes this

- Every Ruby file starts with `# typed: true` (or `strict` where the neighbours are strict) and `# frozen_string_literal: true`.
- Migrations use `ActiveRecord::Migration[8.1]`, UUID v7 keys (`id: :uuid, default: -> { "uuid_generate_v7()" }`), and `up`/`down`. Run `bin/rails db:migrate` and commit the regenerated `db/structure.sql`.
- After adding a model or gem, run `bin/tapioca dsl` (and `bin/tapioca gem <name>` for gems) and commit `sorbet/rbi` changes, or `srb tc` fails in `bin/check`.
- `bin/check` is the gate. It must be green at the end of every task that touches Ruby.
- Commit after every task on the feature branch. Never commit to `master`.
- Steps marked **USER WRITES** are deliberately left for the user. Stop there, show them the prepared file and the guidance, and continue only once they have written it.

---

### Task 0: Branch

**Step 1: Create the branch**

```bash
git checkout -b feature/ui-foundation
git add docs/plans reports research_notes
git commit -m "docs: UI use cases, design, research reports and foundation plan"
```

---

### Task 1: Permission catalogue

**Files:**
- Create: `app/lib/permissions.rb`
- Create: `config/initializers/permissions.rb`
- Test: `spec/lib/permissions_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/lib/permissions_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Permissions do
  describe ".granted?" do
    it "grants a permission the role holds" do
      expect(described_class.granted?(:merchant, "support", "payments.refund")).to be(true)
    end

    it "denies a permission the role lacks" do
      expect(described_class.granted?(:merchant, "developer", "payments.refund")).to be(false)
    end

    it "raises on an unknown permission instead of silently denying" do
      expect { described_class.granted?(:merchant, "owner", "payments.refnud") }
        .to raise_error(Permissions::Unknown, /payments.refnud/)
    end

    it "raises on an unknown role" do
      expect { described_class.granted?(:merchant, "superuser", "payments.read") }
        .to raise_error(ArgumentError, /superuser/)
    end

    it "never grants operator permissions to merchant roles" do
      expect(described_class.granted?(:merchant, "owner", "ops.payments.read")).to be(false)
    end
  end

  describe ".validate!" do
    it "passes for the shipped catalogue" do
      expect { described_class.validate! }.not_to raise_error
    end

    it "keeps merchant and operator permissions in separate namespaces" do
      merchant = described_class::MERCHANT.values.reduce(Set.new, :|)
      operator = described_class::OPERATOR.values.reduce(Set.new, :|)
      expect(merchant.grep(/\Aops\./)).to be_empty
      expect(operator.reject { |p| p.start_with?("ops.") }).to be_empty
    end
  end

  describe "separation of duties" do
    it "gives no operator role both proposals.create and proposals.decide" do
      both = described_class::OPERATOR.select do |_role, perms|
        perms.include?("ops.proposals.create") && perms.include?("ops.proposals.decide")
      end
      expect(both.keys).to be_empty
    end

    it "does not let the operator admin decide proposals" do
      expect(described_class.granted?(:operator, "admin", "ops.proposals.decide")).to be(false)
    end
  end

  describe ".sensitive?" do
    it "marks money-moving and access-granting permissions as sensitive" do
      expect(described_class.sensitive?("payments.refund")).to be(true)
      expect(described_class.sensitive?("team.manage")).to be(true)
      expect(described_class.sensitive?("payments.read")).to be(false)
    end
  end
end
```

**Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/lib/permissions_spec.rb`
Expected: FAIL with `uninitialized constant Permissions`.

**Step 3: Write the catalogue**

```ruby
# app/lib/permissions.rb
# typed: strict
# frozen_string_literal: true

# The single source of truth for who may do what (design §3).
#
# Rules:
# - Code checks permissions, never role names.
# - Permission names are `resource.verb`; operator permissions live under `ops.`.
# - Every role lists its permissions explicitly. No wildcards: a wildcard would
#   silently grant permissions added later.
# - `rake permissions:export` generates docs/permissions.md and the TypeScript
#   union from this file. CI fails if either is stale.
module Permissions
  extend T::Sig

  class Unknown < ArgumentError; end

  CATALOGUE = T.let(
    {
      # ── Merchant ────────────────────────────────────────────────────────
      "payments.read" => { description: "List and view payments and their timelines", sensitive: false },
      "payments.export" => { description: "Export the payment list as CSV", sensitive: false },
      "payments.capture" => { description: "Capture an authorised payment", sensitive: true },
      "payments.cancel" => { description: "Cancel an authorised payment", sensitive: true },
      "payments.refund" => { description: "Refund a captured payment", sensitive: true },
      "balance.read" => { description: "View balances per currency", sensitive: false },
      "settlements.read" => { description: "View settlements and PSP fees", sensitive: false },
      "api_keys.read" => { description: "List API keys (never the secret)", sensitive: false },
      "api_keys.manage" => { description: "Create, roll and revoke API keys", sensitive: true },
      "webhooks.read" => { description: "View the webhook endpoint and delivery log", sensitive: false },
      "webhooks.manage" => { description: "Change the endpoint, reveal or roll the signing secret", sensitive: true },
      "events.redeliver" => { description: "Resend an outbound event", sensitive: false },
      "team.read" => { description: "List team members and invitations", sensitive: false },
      "team.manage" => { description: "Invite, change roles of and remove team members", sensitive: true },
      "security_history.read" => { description: "Read and export the security history", sensitive: false },
      "ownership.transfer" => { description: "Transfer account ownership", sensitive: true },
      # ── Operator ────────────────────────────────────────────────────────
      "ops.payments.read" => { description: "Search and view payments across merchants", sensitive: false },
      "ops.queue.read" => { description: "View the needs-attention queue", sensitive: false },
      "ops.circuits.read" => { description: "View PSP circuit breaker state", sensitive: false },
      "ops.reconciliation.read" => { description: "View reconciliation and settlement breaks", sensitive: false },
      "ops.audit.read" => { description: "Read the operator audit stream", sensitive: false },
      "ops.payments.poll" => { description: "Poll the PSP for one payment now", sensitive: false },
      "ops.events.redeliver" => { description: "Redeliver a dead-lettered event", sensitive: false },
      "ops.impersonation.start" => { description: "View a merchant's dashboard read-only", sensitive: true },
      "ops.reconciliation.review" => { description: "Mark a reconciliation break reviewed", sensitive: false },
      "ops.proposals.create" => { description: "Propose a manual transition or ledger correction", sensitive: true },
      "ops.proposals.decide" => { description: "Approve or reject another operator's proposal", sensitive: true },
      "ops.operators.manage" => { description: "Add operators and assign roles", sensitive: true },
      "ops.access_review.export" => { description: "Export who holds which role", sensitive: false }
    }.freeze,
    T::Hash[String, T::Hash[Symbol, T.untyped]]
  )

  OPS_READ = T.let(
    Set["ops.payments.read", "ops.queue.read", "ops.circuits.read", "ops.reconciliation.read", "ops.audit.read"].freeze,
    T::Set[String]
  )

  MERCHANT = T.let(
    {
      "owner" => Set[
        "payments.read", "payments.export", "payments.capture", "payments.cancel", "payments.refund",
        "balance.read", "settlements.read", "api_keys.read", "api_keys.manage", "webhooks.read",
        "webhooks.manage", "events.redeliver", "team.read", "team.manage", "security_history.read",
        "ownership.transfer"
      ].freeze,
      "admin" => Set[
        "payments.read", "payments.export", "payments.capture", "payments.cancel", "payments.refund",
        "balance.read", "settlements.read", "api_keys.read", "api_keys.manage", "webhooks.read",
        "webhooks.manage", "events.redeliver", "team.read", "team.manage", "security_history.read"
      ].freeze,
      "developer" => Set[
        "payments.read", "api_keys.read", "api_keys.manage", "webhooks.read", "webhooks.manage", "events.redeliver"
      ].freeze,
      "support" => Set["payments.read", "payments.capture", "payments.cancel", "payments.refund"].freeze,
      "viewer" => Set["payments.read", "payments.export", "balance.read", "settlements.read"].freeze
    }.freeze,
    T::Hash[String, T::Set[String]]
  )

  OPERATOR = T.let(
    {
      "support" => (OPS_READ | Set["ops.payments.poll", "ops.events.redeliver", "ops.impersonation.start"]).freeze,
      "ops" => (OPS_READ | Set[
        "ops.payments.poll", "ops.events.redeliver", "ops.impersonation.start",
        "ops.reconciliation.review", "ops.proposals.create"
      ]).freeze,
      "approver" => (OPS_READ | Set["ops.proposals.decide"]).freeze,
      "admin" => (OPS_READ | Set["ops.operators.manage", "ops.access_review.export"]).freeze
    }.freeze,
    T::Hash[String, T::Set[String]]
  )

  AREAS = T.let({ merchant: MERCHANT, operator: OPERATOR }.freeze, T::Hash[Symbol, T::Hash[String, T::Set[String]]])

  sig { params(area: Symbol, role: String, permission: String).returns(T::Boolean) }
  def self.granted?(area, role, permission)
    raise Unknown, "unknown permission #{permission.inspect}" unless CATALOGUE.key?(permission)

    self.for(area, role).include?(permission)
  end

  sig { params(area: Symbol, role: String).returns(T::Set[String]) }
  def self.for(area, role)
    AREAS.fetch(area) { raise ArgumentError, "unknown area #{area.inspect}" }
         .fetch(role) { raise ArgumentError, "unknown #{area} role #{role.inspect}" }
  end

  sig { params(permission: String).returns(T::Boolean) }
  def self.sensitive?(permission)
    CATALOGUE.fetch(permission) { raise Unknown, "unknown permission #{permission.inspect}" }.fetch(:sensitive)
  end

  sig { params(permission: String).returns(T::Boolean) }
  def self.known?(permission) = CATALOGUE.key?(permission)

  # Run at boot (config/initializers/permissions.rb). A role that references a
  # permission missing from the catalogue is a typo, and must stop the app.
  sig { void }
  def self.validate!
    AREAS.each do |area, roles|
      roles.each do |role, perms|
        unknown = perms.to_a - CATALOGUE.keys
        raise Unknown, "#{area} role #{role} references unknown permissions: #{unknown.join(', ')}" if unknown.any?

        wrong_ns = area == :operator ? perms.reject { |p| p.start_with?("ops.") } : perms.select { |p| p.start_with?("ops.") }
        raise ArgumentError, "#{area} role #{role} holds permissions from the other area: #{wrong_ns.join(', ')}" if wrong_ns.any?
      end
    end
  end
end
```

```ruby
# config/initializers/permissions.rb
# frozen_string_literal: true

# Fail at boot, not at the first request, if a role references a permission
# the catalogue does not define.
Rails.application.config.after_initialize { Permissions.validate! }
```

**Step 4: Run the test**

Run: `bundle exec rspec spec/lib/permissions_spec.rb`
Expected: PASS (9 examples).

**Step 5: Commit**

```bash
git add app/lib/permissions.rb config/initializers/permissions.rb spec/lib/permissions_spec.rb
git commit -m "Add the permission catalogue: resource.verb names, fixed roles, boot validation"
```

---

### Task 2: Independent expected matrix

The matrix spec must be able to *disagree* with `Permissions`. Its expectations come from a hand-reviewed YAML file, not from the code under test (research report, "Change" table).

**Files:**
- Create: `spec/fixtures/permission_matrix.yml`
- Test: `spec/lib/permission_matrix_spec.rb`

**Step 1: Write the spec**

```ruby
# spec/lib/permission_matrix_spec.rb
# frozen_string_literal: true

require "rails_helper"

# Expected values live in spec/fixtures/permission_matrix.yml, written by hand.
# Changing who can do what therefore needs two edits: the catalogue and this
# file. The second edit is the reviewable diff.
RSpec.describe "Permission matrix" do
  matrix = YAML.load_file(Rails.root.join("spec/fixtures/permission_matrix.yml"))

  { "merchant" => Permissions::MERCHANT, "operator" => Permissions::OPERATOR }.each do |area, roles|
    area_permissions = Permissions::CATALOGUE.keys.select { |p| p.start_with?("ops.") == (area == "operator") }

    it "lists every #{area} permission, and nothing else" do
      expect(matrix.fetch(area).keys).to match_array(area_permissions)
    end

    area_permissions.each do |permission|
      it "states every #{area} role explicitly for #{permission}" do
        expect(matrix.fetch(area).fetch(permission).keys).to match_array(roles.keys)
      end

      roles.each_key do |role|
        expected = matrix.fetch(area).fetch(permission).fetch(role)
        it "#{area} #{role} #{expected ? 'may' : 'may not'} #{permission}" do
          expect(Permissions.granted?(area.to_sym, role, permission)).to eq(expected)
        end
      end
    end
  end
end
```

**Step 2: USER WRITES `spec/fixtures/permission_matrix.yml`**

Stop here and hand this to the user. Show them the format and the draft below, which is copied from design §3. Their job is to decide, row by row, whether it is really what each role should do. They should change any cell they disagree with and then mirror the change in `app/lib/permissions.rb`. Every cell must be an explicit `true` or `false`, because explicit `false` documents the boundary (GitLab's rule).

```yaml
# The intended access boundary, reviewed by a human. Do not generate this file.
merchant:
  payments.read:         { owner: true,  admin: true,  developer: true,  support: true,  viewer: true  }
  payments.export:       { owner: true,  admin: true,  developer: false, support: false, viewer: true  }
  payments.capture:      { owner: true,  admin: true,  developer: false, support: true,  viewer: false }
  payments.cancel:       { owner: true,  admin: true,  developer: false, support: true,  viewer: false }
  payments.refund:       { owner: true,  admin: true,  developer: false, support: true,  viewer: false }
  balance.read:          { owner: true,  admin: true,  developer: false, support: false, viewer: true  }
  settlements.read:      { owner: true,  admin: true,  developer: false, support: false, viewer: true  }
  api_keys.read:         { owner: true,  admin: true,  developer: true,  support: false, viewer: false }
  api_keys.manage:       { owner: true,  admin: true,  developer: true,  support: false, viewer: false }
  webhooks.read:         { owner: true,  admin: true,  developer: true,  support: false, viewer: false }
  webhooks.manage:       { owner: true,  admin: true,  developer: true,  support: false, viewer: false }
  events.redeliver:      { owner: true,  admin: true,  developer: true,  support: false, viewer: false }
  team.read:             { owner: true,  admin: true,  developer: false, support: false, viewer: false }
  team.manage:           { owner: true,  admin: true,  developer: false, support: false, viewer: false }
  security_history.read: { owner: true,  admin: true,  developer: false, support: false, viewer: false }
  ownership.transfer:    { owner: true,  admin: false, developer: false, support: false, viewer: false }
operator:
  ops.payments.read:         { support: true,  ops: true,  approver: true,  admin: true  }
  ops.queue.read:            { support: true,  ops: true,  approver: true,  admin: true  }
  ops.circuits.read:         { support: true,  ops: true,  approver: true,  admin: true  }
  ops.reconciliation.read:   { support: true,  ops: true,  approver: true,  admin: true  }
  ops.audit.read:            { support: true,  ops: true,  approver: true,  admin: true  }
  ops.payments.poll:         { support: true,  ops: true,  approver: false, admin: false }
  ops.events.redeliver:      { support: true,  ops: true,  approver: false, admin: false }
  ops.impersonation.start:   { support: true,  ops: true,  approver: false, admin: false }
  ops.reconciliation.review: { support: false, ops: true,  approver: false, admin: false }
  ops.proposals.create:      { support: false, ops: true,  approver: false, admin: false }
  ops.proposals.decide:      { support: false, ops: false, approver: true,  admin: false }
  ops.operators.manage:      { support: false, ops: false, approver: false, admin: true  }
  ops.access_review.export:  { support: false, ops: false, approver: false, admin: true  }
```

**Step 3: Run the spec**

Run: `bundle exec rspec spec/lib/permission_matrix_spec.rb`
Expected: PASS. If a cell fails, the catalogue and the reviewed intent disagree. Ask the user which one is right; never "fix" the YAML to match the code.

**Step 4: Commit**

```bash
git add spec/fixtures/permission_matrix.yml spec/lib/permission_matrix_spec.rb
git commit -m "Test the permission catalogue against an independently reviewed matrix"
```

---

### Task 3: Generated docs and TypeScript permission type

**Files:**
- Create: `app/lib/permissions_export.rb`
- Create: `lib/tasks/permissions.rake`
- Create (generated): `docs/permissions.md`, `app/frontend/shared/permissions.ts`
- Modify: `bin/check`
- Test: `spec/lib/permissions_export_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/lib/permissions_export_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe PermissionsExport do
  describe ".markdown" do
    subject(:markdown) { described_class.markdown }

    it "has one row per permission with its description" do
      expect(markdown).to include("| `payments.refund` | Refund a captured payment |")
    end

    it "marks sensitive permissions" do
      expect(markdown).to match(/\| `payments\.refund` \|[^\n]*\| yes \|/)
    end

    it "says it is generated" do
      expect(markdown).to start_with("<!-- Generated by `bin/rails permissions:export`")
    end
  end

  describe ".typescript" do
    subject(:ts) { described_class.typescript }

    it "exports a union type of merchant permissions" do
      expect(ts).to include(%(export type MerchantPermission =\n  | "balance.read"))
    end

    it "exports a union type of operator permissions" do
      expect(ts).to include(%(  | "ops.proposals.decide"))
    end
  end
end
```

**Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/lib/permissions_export_spec.rb`
Expected: FAIL with `uninitialized constant PermissionsExport`.

**Step 3: Implement**

```ruby
# app/lib/permissions_export.rb
# typed: true
# frozen_string_literal: true

# Renders the permission catalogue for humans (docs/permissions.md) and for the
# Vue app (a TypeScript union), so neither can drift from app/lib/permissions.rb.
module PermissionsExport
  HEADER = "<!-- Generated by `bin/rails permissions:export` from app/lib/permissions.rb. Do not edit. -->"

  def self.markdown
    [HEADER, "", "# Permissions", "", section("Merchant", Permissions::MERCHANT, merchant: true), "",
     section("Operator", Permissions::OPERATOR, merchant: false), ""].join("\n")
  end

  def self.typescript
    <<~TS
      // Generated by `bin/rails permissions:export` from app/lib/permissions.rb. Do not edit.
      export type MerchantPermission =
      #{union(merchant_permissions)}

      export type OperatorPermission =
      #{union(operator_permissions)}
    TS
  end

  def self.merchant_permissions = Permissions::CATALOGUE.keys.reject { |p| p.start_with?("ops.") }.sort
  def self.operator_permissions = Permissions::CATALOGUE.keys.select { |p| p.start_with?("ops.") }.sort

  def self.union(names) = names.map { |n| %(  | "#{n}") }.join("\n") + ";"

  def self.section(title, roles, merchant:)
    names = merchant ? merchant_permissions : operator_permissions
    head = "| Permission | Description | #{roles.keys.join(' | ')} | Sensitive |"
    sep = "|---|---|#{roles.keys.map { ':-:' }.join('|')}|:-:|"
    rows = names.map do |name|
      entry = Permissions::CATALOGUE.fetch(name)
      cells = roles.values.map { |perms| perms.include?(name) ? "✓" : "" }
      "| `#{name}` | #{entry.fetch(:description)} | #{cells.join(' | ')} | #{entry.fetch(:sensitive) ? 'yes' : ''} |"
    end
    ["## #{title}", "", head, sep, *rows].join("\n")
  end
end
```

```ruby
# lib/tasks/permissions.rake
# frozen_string_literal: true

namespace :permissions do
  desc "Write docs/permissions.md and app/frontend/shared/permissions.ts from app/lib/permissions.rb"
  task export: :environment do
    File.write(Rails.root.join("docs/permissions.md"), PermissionsExport.markdown)
    FileUtils.mkdir_p(Rails.root.join("app/frontend/shared"))
    File.write(Rails.root.join("app/frontend/shared/permissions.ts"), PermissionsExport.typescript)
    puts "Wrote docs/permissions.md and app/frontend/shared/permissions.ts"
  end
end
```

**Step 4: Run tests, generate, and add the staleness gate**

Run: `bundle exec rspec spec/lib/permissions_export_spec.rb`
Expected: PASS.

Run: `bin/rails permissions:export`
Expected: `Wrote docs/permissions.md and app/frontend/shared/permissions.ts`. Open `docs/permissions.md` and check the tables read correctly.

Add this step to `bin/check`, directly after the zeitwerk step:

```bash
step "permissions (generated files are current)"
bin/rails permissions:export >/dev/null
git diff --exit-code -- docs/permissions.md app/frontend/shared/permissions.ts \
  || { echo "Run bin/rails permissions:export and commit the result."; exit 1; }
```

**Step 5: Commit**

```bash
git add app/lib/permissions_export.rb lib/tasks/permissions.rake spec/lib/permissions_export_spec.rb \
        docs/permissions.md app/frontend/shared/permissions.ts bin/check
git commit -m "Generate permission docs and a TypeScript union from the catalogue; fail CI when stale"
```

---

### Task 4: Append-only audit log

**Files:**
- Create: `db/migrate/20260925000001_create_audit_events.rb`
- Create: `app/models/audit_event.rb`
- Test: `spec/models/audit_event_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/models/audit_event_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditEvent do
  let(:merchant) { create(:merchant) }

  it "records an event with its context" do
    event = described_class.record!(action: "authorization.denied", result: "denied", merchant_id: merchant.id,
                                    actor_label: "sam@example.com", ip: "10.0.0.1",
                                    metadata: { "permission" => "payments.refund" })
    expect(event.reload.metadata).to eq("permission" => "payments.refund")
  end

  it "rejects an unknown result" do
    expect { described_class.record!(action: "x", result: "maybe") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "cannot be updated, even bypassing Rails" do
    event = described_class.record!(action: "session.created", result: "success")
    expect { described_class.where(id: event.id).update_all(action: "tampered") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "cannot delete rows younger than 12 months" do
    event = described_class.record!(action: "session.created", result: "success")
    expect { described_class.where(id: event.id).delete_all }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "allows the retention purge to delete rows older than 12 months" do
    event = travel_to(13.months.ago) { described_class.record!(action: "session.created", result: "success") }
    expect { described_class.where(id: event.id).delete_all }.to change(described_class, :count).by(-1)
  end
end
```

**Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/models/audit_event_spec.rb`
Expected: FAIL with `uninitialized constant AuditEvent`.

**Step 3: Migration and model**

```ruby
# db/migrate/20260925000001_create_audit_events.rb
class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def up
    # One guard for every append-only table after the ledger. The optional
    # argument is a retention interval: rows older than it may be deleted by the
    # purge job, and nothing else can ever be changed.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION append_only_guard() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND TG_NARGS > 0
           AND OLD.created_at < now() - TG_ARGV[0]::interval THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION '% is append-only (attempted %)', TG_TABLE_NAME, TG_OP;
      END
      $$ LANGUAGE plpgsql;
    SQL

    create_table :audit_events, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :actor_type                 # MerchantUser, Operator, or NULL for anonymous
      t.uuid :actor_id
      t.string :actor_label                # email at the time, kept even if the user is deleted
      t.uuid :merchant_id                  # tenant the event belongs to (server-verified)
      t.uuid :on_behalf_of_merchant_id     # set while an operator views as a merchant
      t.string :action, null: false        # e.g. authorization.denied, api_key.rolled
      t.string :target_type
      t.uuid :target_id
      t.string :result, null: false
      t.string :ip
      t.string :user_agent
      t.string :request_id
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_check_constraint :audit_events, "result IN ('success', 'denied', 'failure')", name: "chk_audit_events_result"
    add_index :audit_events, %i[merchant_id created_at]
    add_index :audit_events, %i[actor_type actor_id created_at]
    add_index :audit_events, %i[action created_at]

    execute <<~SQL
      CREATE TRIGGER trg_audit_events_append_only
        BEFORE UPDATE OR DELETE ON audit_events
        FOR EACH ROW EXECUTE FUNCTION append_only_guard('12 months');
    SQL
  end

  def down
    drop_table :audit_events
    execute "DROP FUNCTION IF EXISTS append_only_guard()"
  end
end
```

```ruby
# app/models/audit_event.rb
# typed: true
# frozen_string_literal: true

# Who did what, to what, with what result (PCI DSS 10.2.2). Append-only in the
# database; kept 12 months. Never store request bodies, tokens or session ids.
class AuditEvent < ApplicationRecord
  RESULTS = %w[success denied failure].freeze

  validates :action, presence: true
  validates :result, inclusion: { in: RESULTS }

  def readonly? = persisted?

  def self.record!(action:, result:, actor: nil, actor_label: nil, merchant_id: nil, on_behalf_of_merchant_id: nil,
                   target: nil, ip: nil, user_agent: nil, request_id: nil, metadata: {})
    create!(action:, result:, actor_type: actor&.class&.name, actor_id: actor&.id, actor_label:,
            merchant_id:, on_behalf_of_merchant_id:, target_type: target&.class&.name, target_id: target&.id,
            ip:, user_agent: user_agent&.truncate(255), request_id:, metadata:)
  end
end
```

**Step 4: Migrate and run**

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate && bundle exec rspec spec/models/audit_event_spec.rb`
Expected: PASS (5 examples).

**Step 5: Commit**

```bash
bin/tapioca dsl
git add db/migrate/20260925000001_create_audit_events.rb db/structure.sql app/models/audit_event.rb \
        spec/models/audit_event_spec.rb sorbet/rbi
git commit -m "Add the append-only audit log with a 12-month retention window"
```

---

### Task 5: API keys table and backfill

**Files:**
- Create: `db/migrate/20260925000002_create_api_keys.rb`
- Create: `app/models/api_key.rb`
- Modify: `app/models/merchant.rb` (add `has_many :api_keys`)
- Test: `spec/models/api_key_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/models/api_key_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiKey do
  let(:merchant) { create(:merchant) }

  describe ".issue!" do
    it "returns the raw key once and stores only its digest, prefix and last 4" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      expect(raw).to start_with("sk_live_")
      expect(key.digest).to eq(Digest::SHA256.hexdigest(raw))
      expect(key.prefix).to eq("sk_live_")
      expect(key.last4).to eq(raw[-4..])
      expect(key.attributes.values).not_to include(raw)
    end

    it "issues test keys with the sk_test_ prefix" do
      _key, raw = described_class.issue!(merchant:, livemode: false, name: "CI")
      expect(raw).to start_with("sk_test_")
    end
  end

  describe ".authenticate" do
    it "finds an active key" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      expect(described_class.authenticate(raw)).to eq(key)
    end

    it "rejects a revoked key" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      key.update!(revoked_at: Time.current)
      expect(described_class.authenticate(raw)).to be_nil
    end

    it "accepts a rolled key until it expires, then rejects it" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      key.update!(expires_at: 1.hour.from_now)
      expect(described_class.authenticate(raw)).to eq(key)
      travel 2.hours
      expect(described_class.authenticate(raw)).to be_nil
    end

    it "records last use at most once a minute" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      freeze_time do
        described_class.authenticate(raw)
        expect(key.reload.last_used_at).to eq(Time.current)
        travel 30.seconds
        described_class.authenticate(raw)
        expect(key.reload.last_used_at).to eq(30.seconds.ago)
      end
    end

    it "returns nil for blank input" do
      expect(described_class.authenticate("")).to be_nil
    end
  end
end
```

**Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/models/api_key_spec.rb`
Expected: FAIL with `uninitialized constant ApiKey`.

**Step 3: Migration, backfill and model**

```ruby
# db/migrate/20260925000002_create_api_keys.rb
class CreateApiKeys < ActiveRecord::Migration[8.1]
  # Many keys per merchant, so keys can be named, rolled with overlap and
  # revoked (design §2). merchants.api_key_digest stays until a later migration
  # drops it; this one only copies it.
  def up
    create_table :api_keys, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :merchant, type: :uuid, null: false, foreign_key: true
      t.boolean :livemode, null: false
      t.string :name, null: false
      t.string :note                        # "where is this key stored?"
      t.string :prefix, null: false         # sk_live_ / sk_test_
      t.string :last4                       # NULL for keys migrated from the digest column
      t.string :digest, null: false
      t.uuid :created_by_id                 # merchant_users arrives in phase 1; FK added then
      t.datetime :last_used_at
      t.datetime :expires_at                # set when rolled: the overlap window
      t.datetime :revoked_at                # set when revoked; rows are never deleted
      t.timestamps
    end
    add_index :api_keys, :digest, unique: true
    add_check_constraint :api_keys, "prefix IN ('sk_live_', 'sk_test_')", name: "chk_api_keys_prefix"

    execute <<~SQL
      INSERT INTO api_keys (merchant_id, livemode, name, prefix, digest, created_at, updated_at)
      SELECT id, true, 'Migrated key', 'sk_live_', api_key_digest, now(), now() FROM merchants;
    SQL
  end

  def down
    drop_table :api_keys
  end
end
```

```ruby
# app/models/api_key.rb
# typed: true
# frozen_string_literal: true

# A merchant's secret key. The raw key is returned once by .issue! and never
# stored; lookups go through its SHA-256 digest, which is safe for 192-bit
# random keys (slow hashes protect low-entropy passwords, not these).
class ApiKey < ApplicationRecord
  LIVE_PREFIX = "sk_live_"
  TEST_PREFIX = "sk_test_"
  LAST_USED_RESOLUTION = 1.minute

  belongs_to :merchant

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  validates :name, presence: true

  # Returns [key, raw]. Show raw to the person exactly once.
  def self.issue!(merchant:, livemode:, name:, note: nil, created_by_id: nil)
    raw = "#{livemode ? LIVE_PREFIX : TEST_PREFIX}#{SecureRandom.hex(24)}"
    key = create!(merchant:, livemode:, name:, note:, created_by_id:,
                  prefix: livemode ? LIVE_PREFIX : TEST_PREFIX, last4: raw[-4..], digest: Merchant.digest(raw))
    [key, raw]
  end

  def self.authenticate(raw)
    return nil if raw.blank?

    candidate = Merchant.digest(raw)
    key = active.find_by(digest: candidate)
    return nil unless key && ActiveSupport::SecurityUtils.secure_compare(key.digest, candidate)

    key.touch_last_used!
    key
  end

  def touch_last_used!
    return if last_used_at && last_used_at > LAST_USED_RESOLUTION.ago

    update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations -- hot path, no validations to run
  end
end
```

In `app/models/merchant.rb`, below the existing `has_many` lines, add:

```ruby
  has_many :api_keys, dependent: :restrict_with_exception
```

**Step 4: Migrate and run**

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate && bundle exec rspec spec/models/api_key_spec.rb`
Expected: PASS (7 examples).

**Step 5: Commit**

```bash
bin/tapioca dsl
git add db/migrate/20260925000002_create_api_keys.rb db/structure.sql app/models/api_key.rb app/models/merchant.rb \
        spec/models/api_key_spec.rb sorbet/rbi
git commit -m "Add api_keys: many keys per merchant, rolled with overlap, revoked not deleted"
```

---

### Task 6: Authenticate the /v1 API through api_keys

**Files:**
- Modify: `app/models/merchant.rb:18-38` (`create_with_api_key!`, `authenticate`)
- Test: `spec/models/merchant_spec.rb` (add examples)

**Step 1: Write the failing tests**

Add inside `RSpec.describe Merchant`, in the existing `describe ".create_with_api_key! / .authenticate"` block:

```ruby
    it "stores the key in api_keys" do
      merchant, raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")
      expect(merchant.api_keys.sole.digest).to eq(Digest::SHA256.hexdigest(raw))
    end

    it "stops authenticating once the key is revoked" do
      merchant, raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")
      merchant.api_keys.sole.update!(revoked_at: Time.current)
      expect(described_class.authenticate(raw)).to be_nil
    end

    it "authenticates a second key issued later" do
      merchant, _raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")
      _key, second = ApiKey.issue!(merchant:, livemode: true, name: "Second")
      expect(described_class.authenticate(second)).to eq(merchant)
    end
```

**Step 2: Run and watch them fail**

Run: `bundle exec rspec spec/models/merchant_spec.rb`
Expected: the three new examples FAIL; existing ones pass.

**Step 3: Implement**

Replace `self.create_with_api_key!` and `self.authenticate` in `app/models/merchant.rb`:

```ruby
  # Returns [merchant, raw_key]. The raw key is shown to the merchant once
  # and never stored — only its digest is. api_key_digest is still written
  # until the column is dropped (design §2, two-step migration).
  def self.create_with_api_key!(attrs)
    transaction do
      merchant = create!(attrs.merge(api_key_digest: digest(SecureRandom.hex(32)), webhook_secret: SecureRandom.hex(32)))
      key, raw = ApiKey.issue!(merchant:, livemode: true, name: "Default key")
      merchant.update!(api_key_digest: key.digest)
      [merchant, raw]
    end
  end

  # Constant-time lookup, now through api_keys so revoked and expired keys stop
  # working and many keys can be active at once.
  def self.authenticate(raw_key)
    ApiKey.authenticate(raw_key)&.merchant
  end
```

**Step 4: Run the whole suite**

Run: `bundle exec rspec`
Expected: PASS. The existing merchant spec asserting `api_key_digest == digest(raw)` still passes because the column is kept in sync. If any request spec built a merchant with the factory and a hand-made key, switch it to `create_merchant_with_key`.

**Step 5: Commit**

```bash
git add app/models/merchant.rb spec/models/merchant_spec.rb
git commit -m "Authenticate /v1 through api_keys so keys can be revoked and rolled"
```

---

### Task 7: Test-mode twin merchants

**Files:**
- Create: `db/migrate/20260925000003_add_test_twins_to_merchants.rb`
- Modify: `app/models/merchant.rb`, `app/models/api_key.rb`, `db/seeds.rb`
- Test: `spec/models/merchant_spec.rb`, `spec/requests/v1/test_mode_spec.rb`

**Step 1: Write the failing tests**

```ruby
# add to spec/models/merchant_spec.rb
  describe "#test_twin!" do
    it "creates one test-mode twin linked to the live merchant" do
      merchant = create(:merchant)
      twin = merchant.test_twin!
      expect(twin).to have_attributes(livemode: false, live_merchant_id: merchant.id,
                                      default_currency: merchant.default_currency)
      expect(merchant.test_twin!).to eq(twin)
    end
  end
```

```ruby
# spec/requests/v1/test_mode_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Test mode separation" do
  let!(:live) { create_merchant_with_key }
  let(:merchant) { live.first }
  let(:live_key) { live.last }
  let(:test_key) { ApiKey.issue!(merchant:, livemode: false, name: "Test").last }

  it "authenticates a test key as the test twin" do
    expect(Merchant.authenticate(test_key)).to eq(merchant.test_twin!)
  end

  it "never shows test payments to a live key" do
    post "/v1/payments", headers: auth_headers(test_key),
                         params: { amount_minor: 2500, currency: "EUR", payment_method_token: "tok_visa" }.to_json
    expect(response).to have_http_status(:accepted)

    get "/v1/payments", headers: auth_headers(live_key)
    expect(json_body.fetch("data")).to be_empty

    get "/v1/payments", headers: auth_headers(test_key)
    expect(json_body.fetch("data").size).to eq(1)
  end
end
```

Check the list response shape in `spec/requests/v1/payments_index_spec.rb` first; if the key is not `data`, use the key it uses.

**Step 2: Run and watch them fail**

Run: `bundle exec rspec spec/models/merchant_spec.rb spec/requests/v1/test_mode_spec.rb`
Expected: FAIL with `undefined method 'test_twin!'`.

**Step 3: Migration and model changes**

```ruby
# db/migrate/20260925000003_add_test_twins_to_merchants.rb
class AddTestTwinsToMerchants < ActiveRecord::Migration[8.1]
  # Test mode is a second merchant row (design §2). Every query is already
  # scoped by merchant_id, so test and live data are separated by scoping that
  # exists, with no livemode column on payments, refunds or the ledger.
  def up
    add_column :merchants, :livemode, :boolean, null: false, default: true
    add_reference :merchants, :live_merchant, type: :uuid, foreign_key: { to_table: :merchants },
                                              index: { unique: true, name: "idx_merchants_one_test_twin" }
    add_check_constraint :merchants, "livemode = (live_merchant_id IS NULL)", name: "chk_merchants_twin_shape"
  end

  def down
    remove_check_constraint :merchants, name: "chk_merchants_twin_shape"
    remove_reference :merchants, :live_merchant
    remove_column :merchants, :livemode
  end
end
```

In `app/models/merchant.rb` add:

```ruby
  belongs_to :live_merchant, class_name: "Merchant", optional: true
  has_one :test_twin, class_name: "Merchant", foreign_key: :live_merchant_id,
                      inverse_of: :live_merchant, dependent: :restrict_with_exception

  # The test-mode twin, created on first use. The unique index makes a
  # concurrent second create fail, and we then read the winner's row.
  def test_twin!
    raise ArgumentError, "a test twin has no twin" unless livemode

    test_twin || Merchant.create!(
      name: "#{name} (test)", livemode: false, live_merchant: self, default_currency:, webhook_url:,
      # Placeholder until api_key_digest is dropped: nobody holds this key.
      api_key_digest: Merchant.digest(SecureRandom.hex(32)), webhook_secret: SecureRandom.hex(32)
    )
  rescue ActiveRecord::RecordNotUnique
    reload.test_twin || raise
  end
```

In `app/models/api_key.rb` add a validation and the mode switch:

```ruby
  validate :belongs_to_live_merchant

  # Which data space this key opens: the live merchant or its test twin.
  def merchant_for_mode = livemode ? merchant : merchant.test_twin!

  private

  def belongs_to_live_merchant
    errors.add(:merchant, "must be the live merchant; test keys open its twin") unless merchant&.livemode
  end
```

In `app/models/merchant.rb`, change `authenticate` to use it:

```ruby
  def self.authenticate(raw_key)
    ApiKey.authenticate(raw_key)&.merchant_for_mode
  end
```

In `db/seeds.rb`, after the demo merchant and its live key are printed, issue and print a test key the same way (only when the merchant was just created, to keep the seed idempotent):

```ruby
  _test_key, test_raw = ApiKey.issue!(merchant:, livemode: false, name: "Default test key")
  puts "Demo merchant TEST key (shown once): #{test_raw}"
```

**Step 4: Migrate and run the suite**

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate && bundle exec rspec`
Expected: PASS, including `spec/simulation` and `spec/properties`.

**Step 5: Commit**

```bash
bin/tapioca dsl
git add db/migrate/20260925000003_add_test_twins_to_merchants.rb db/structure.sql app/models/merchant.rb \
        app/models/api_key.rb db/seeds.rb spec/models/merchant_spec.rb spec/requests/v1/test_mode_spec.rb sorbet/rbi
git commit -m "Separate test mode with a twin merchant per live merchant"
```

---

### Task 8: Record every outbound PSP call

**Files:**
- Create: `db/migrate/20260925000004_create_psp_calls.rb`
- Create: `app/models/psp_call.rb`, `app/lib/psp_call_redactor.rb`, `app/lib/psp_call_log.rb`
- Modify: `app/adapters/nordpay_adapter.rb` (`send_request`), `app/adapters/kiripay_adapter.rb` (`send_request`), `app/lib/metrics.rb` (`COUNTERS`)
- Test: `spec/lib/psp_call_redactor_spec.rb`, `spec/lib/psp_call_log_spec.rb`, `spec/adapters/nordpay_adapter_spec.rb` (add examples)

**Step 1: Migration and model**

```ruby
# db/migrate/20260925000004_create_psp_calls.rb
class CreatePspCalls < ActiveRecord::Migration[8.1]
  # Evidence for the operator payment view (design decision 1). A timeout is a
  # row with no response: it is exactly the call that put a payment in `unknown`.
  def up
    create_table :psp_calls, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :psp_name, null: false
      t.string :operation, null: false        # e.g. "POST /charges", "GET /charges/:ref"
      t.string :psp_reference                 # ph_… or phr_… when the call is about one
      t.integer :http_status                  # NULL on timeout / unreachable
      t.string :outcome, null: false
      t.jsonb :request_redacted
      t.jsonb :response_redacted
      t.integer :duration_ms, null: false
      t.datetime :sent_at, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :psp_calls, "outcome IN ('ok', 'http_error', 'timeout', 'unreachable')", name: "chk_psp_calls_outcome"
    add_index :psp_calls, %i[psp_name psp_reference sent_at]
    execute <<~SQL
      CREATE TRIGGER trg_psp_calls_append_only
        BEFORE UPDATE OR DELETE ON psp_calls
        FOR EACH ROW EXECUTE FUNCTION append_only_guard('12 months');
    SQL
  end

  def down
    drop_table :psp_calls
  end
end
```

```ruby
# app/models/psp_call.rb
# typed: true
# frozen_string_literal: true

class PspCall < ApplicationRecord
  OUTCOMES = %w[ok http_error timeout unreachable].freeze
  validates :outcome, inclusion: { in: OUTCOMES }
  def readonly? = persisted?
end
```

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate`

**Step 2: Write the redactor spec**

```ruby
# spec/lib/psp_call_redactor_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe PspCallRedactor do
  it "removes the payment method token" do
    expect(described_class.redact({ "payment_method_token" => "tok_visa", "amount" => 2500 }))
      .to eq({ "payment_method_token" => "[REDACTED]", "amount" => 2500 })
  end

  it "redacts anything that looks like a card number, wherever it is" do
    redacted = described_class.redact({ "source" => { "number" => "4242424242424242" } })
    expect(redacted.to_json).not_to include("4242424242424242")
  end

  it "redacts secrets and signatures by key name, case-insensitively" do
    redacted = described_class.redact({ "Authorization" => "Bearer x", "webhook_secret" => "s", "Signature" => "sig" })
    expect(redacted.values.uniq).to eq(["[REDACTED]"])
  end

  it "keeps references, amounts, states and decline codes" do
    body = { "reference" => "ph_abc", "amount" => 2500, "status" => "declined", "decline_code" => "insufficient_funds" }
    expect(described_class.redact(body)).to eq(body)
  end

  it "walks arrays" do
    expect(described_class.redact({ "charges" => [{ "payment_method_token" => "tok" }] }))
      .to eq({ "charges" => [{ "payment_method_token" => "[REDACTED]" }] })
  end

  it "passes nil through" do
    expect(described_class.redact(nil)).to be_nil
  end
end
```

Run: `bundle exec rspec spec/lib/psp_call_redactor_spec.rb`
Expected: FAIL with `uninitialized constant PspCallRedactor`.

**Step 3: USER WRITES `PspCallRedactor.redact`**

Create the file with the signature and hand it to the user:

```ruby
# app/lib/psp_call_redactor.rb
# typed: true
# frozen_string_literal: true

# Strips anything sensitive from a PSP request or response body before it is
# stored in psp_calls. Runs on every call, so it must never raise.
module PspCallRedactor
  MASK = "[REDACTED]"

  # @param body [Hash, Array, String, Integer, nil] a parsed JSON value
  # @return the same shape, with sensitive values replaced by MASK
  def self.redact(body)
    # TODO(user): 5-10 lines. Decide:
    # - which KEY NAMES are always sensitive (token? secret? signature? authorization? cvc?),
    #   matched case-insensitively;
    # - which VALUES are sensitive wherever they appear (13-19 digit card-like numbers);
    # - recurse into Hash and Array; leave everything else untouched.
    # Trade-off: a broad key list hides more debugging detail from operators;
    # a narrow one risks storing a secret in a 12-month append-only table
    # that cannot be scrubbed afterwards.
    raise NotImplementedError
  end
end
```

Continue once `bundle exec rspec spec/lib/psp_call_redactor_spec.rb` passes.

**Step 4: Write the log spec**

```ruby
# spec/lib/psp_call_log_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe PspCallLog do
  let(:started) { Time.current }

  it "records a response with redacted bodies and the reference from the path" do
    described_class.record(psp: "nordpay", method: :get, path: "/charges/ph_#{'a' * 24}", request_body: nil,
                           status: 200, response_body: { "status" => "authorized" }, outcome: "ok", started_at: started)
    call = PspCall.sole
    expect(call).to have_attributes(psp_reference: "ph_#{'a' * 24}", operation: "GET /charges/:ref", http_status: 200)
  end

  it "records a timeout with no response" do
    described_class.record(psp: "nordpay", method: :post, path: "/charges",
                           request_body: { reference: "ph_#{'b' * 24}", payment_method_token: "tok_visa" },
                           status: nil, response_body: nil, outcome: "timeout", started_at: started)
    call = PspCall.sole
    expect(call).to have_attributes(outcome: "timeout", http_status: nil, response_redacted: nil,
                                    psp_reference: "ph_#{'b' * 24}")
    expect(call.request_redacted.to_json).not_to include("tok_visa")
  end

  it "never lets a logging failure break the PSP call" do
    allow(PspCall).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect do
      described_class.record(psp: "nordpay", method: :get, path: "/x", request_body: nil, status: 200,
                             response_body: nil, outcome: "ok", started_at: started)
    end.not_to raise_error
  end
end
```

Run: `bundle exec rspec spec/lib/psp_call_log_spec.rb`
Expected: FAIL with `uninitialized constant PspCallLog`.

**Step 5: Implement the log**

Add `psp_call_log_failures: [:psp]` to `Metrics::COUNTERS` in `app/lib/metrics.rb`.

```ruby
# app/lib/psp_call_log.rb
# typed: true
# frozen_string_literal: true

# Writes one psp_calls row per outbound PSP request. Logging must never change
# payment behaviour, so a failure here is logged and counted, never raised.
module PspCallLog
  REFERENCE = /\bphr?_[a-f0-9]{24}\b/

  def self.record(psp:, method:, path:, request_body:, status:, response_body:, outcome:, started_at:)
    PspCall.create!(
      psp_name: psp,
      operation: "#{method.to_s.upcase} #{path.gsub(REFERENCE, ':ref')}",
      psp_reference: path[REFERENCE] || request_body.to_json[REFERENCE],
      http_status: status,
      outcome:,
      request_redacted: PspCallRedactor.redact(request_body&.deep_stringify_keys),
      response_redacted: PspCallRedactor.redact(response_body),
      duration_ms: ((Time.current - started_at) * 1000).round,
      sent_at: started_at
    )
  rescue StandardError => e
    Rails.logger.error({ event: "psp_call_log_failed", psp:, error: e.class.name }.to_json)
    Metrics.increment(:psp_call_log_failures, psp:)
  end
end
```

Run: `bundle exec rspec spec/lib/psp_call_log_spec.rb`
Expected: PASS.

**Step 6: Wire it into both adapters**

In `app/adapters/nordpay_adapter.rb#send_request`, capture the start time and record at each exit. The method becomes:

```ruby
  def send_request(method, path, body: nil, headers: {})
    operation = "#{method.upcase} #{path.sub(%r{/ph_[a-f0-9]+}, '/:ref')}"
    started_at = Time.current
    response = @conn.run_request(method, path, body, headers)
    outcome = response.status.between?(200, 299) ? "ok" : "http_#{response.status}"
    Metrics.increment(:psp_calls, psp: "nordpay", operation: operation, outcome: outcome)
    PspCallLog.record(psp: "nordpay", method:, path:, request_body: body, status: response.status,
                      response_body: response.body, outcome: outcome == "ok" ? "ok" : "http_error", started_at:)
    case response.status
    when 200..299, 404 then response
    when 500..599 then raise Unavailable, "nordpay #{response.status}: #{error_message(response)}"
    else raise Rejected.new(response.status, "nordpay #{response.status}: #{error_message(response)}")
    end
  rescue Faraday::TimeoutError => e
    Metrics.increment(:psp_calls, psp: "nordpay", operation: operation, outcome: "timeout")
    PspCallLog.record(psp: "nordpay", method:, path:, request_body: body, status: nil, response_body: nil,
                      outcome: "timeout", started_at: T.must(started_at))
    raise TimedOut, "nordpay #{method.upcase} #{path}: #{e.message}"
  rescue Faraday::ConnectionFailed => e
    Metrics.increment(:psp_calls, psp: "nordpay", operation: operation, outcome: "unreachable")
    PspCallLog.record(psp: "nordpay", method:, path:, request_body: body, status: nil, response_body: nil,
                      outcome: "unreachable", started_at: T.must(started_at))
    raise Unavailable, "nordpay unreachable: #{e.message}"
  end
```

Make the same change in `app/adapters/kiripay_adapter.rb#send_request`, with `"kiripay"`.

Add to `spec/adapters/nordpay_adapter_spec.rb` (it already stubs HTTP with WebMock; reuse its setup for the charge path and reference):

```ruby
  it "records a timed-out charge as a psp_calls row with no response" do
    stub_request(:post, %r{/charges}).to_timeout
    expect { adapter.authorize(payment) }.to raise_error(PspAdapter::TimedOut)
    expect(PspCall.sole).to have_attributes(outcome: "timeout", psp_reference: payment.psp_reference, http_status: nil)
  end
```

Then check the callers: if any job calls the adapter **inside** a database transaction that is rolled back on `TimedOut`, the row is rolled back with it. Search with `grep -rn "transaction" app/jobs app/services` and read each hit around an adapter call. DECISIONS #13 says locks are released before HTTP calls, so none are expected; if one is found, note it in the PR instead of changing job behaviour in this plan.

**Step 7: Run the suite and commit**

Run: `bundle exec rspec`
Expected: PASS, including the simulation and property specs.

```bash
bin/tapioca dsl
git add db/migrate/20260925000004_create_psp_calls.rb db/structure.sql app/models/psp_call.rb \
        app/lib/psp_call_redactor.rb app/lib/psp_call_log.rb app/lib/metrics.rb \
        app/adapters/nordpay_adapter.rb app/adapters/kiripay_adapter.rb \
        spec/lib/psp_call_redactor_spec.rb spec/lib/psp_call_log_spec.rb spec/adapters/nordpay_adapter_spec.rb sorbet/rbi
git commit -m "Record every outbound PSP call, redacted, including timeouts"
```

---

### Task 9: Web base controller and fail-closed authorization

**Files:**
- Modify: `config/application.rb` (cookie and session middleware for the UI)
- Modify: `app/lib/api_error.rb` (add `forbidden`), `app/lib/metrics.rb` (add counters)
- Create: `app/controllers/concerns/authorization.rb`
- Create: `app/controllers/web/base_controller.rb`
- Test: `spec/controllers/authorization_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/controllers/authorization_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Web::BaseController, type: :controller do
  controller(described_class) do
    requires_permission "payments.refund", only: :create
    requires_permission "payments.read", only: :index
    allow_unauthorized only: :show

    attr_accessor :test_role

    def index = render(json: { ok: true })
    def create = render(json: { ok: true })
    def show = render(json: { ok: true })
    def destroy = render(json: { ok: true }) # declared nowhere

    private

    def authorization_area = :merchant
    def authorization_role = request.headers["X-Test-Role"]
  end

  before { routes.draw { resources :anonymous } }

  it "allows a role that holds the permission" do
    request.headers["X-Test-Role"] = "support"
    post :create
    expect(response).to have_http_status(:ok)
  end

  it "denies with 403 and the standard error shape" do
    request.headers["X-Test-Role"] = "viewer"
    post :create
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("forbidden")
  end

  it "audits the denial with the permission and route, never the body" do
    request.headers["X-Test-Role"] = "viewer"
    expect { post :create, params: { secret: "x" } }.to change(AuditEvent, :count).by(1)
    event = AuditEvent.last
    expect(event).to have_attributes(action: "authorization.denied", result: "denied")
    expect(event.metadata).to include("permission" => "payments.refund", "role" => "viewer")
    expect(event.metadata.to_json).not_to include("secret")
  end

  it "runs an explicitly public action without a role" do
    get :show, params: { id: 1 }
    expect(response).to have_http_status(:ok)
  end

  it "raises in test when an action declares nothing" do
    request.headers["X-Test-Role"] = "owner"
    expect { delete :destroy, params: { id: 1 } }.to raise_error(Authorization::NotDeclared, /destroy/)
  end

  it "rejects an unknown permission at declaration time" do
    expect { Class.new(described_class) { requires_permission "payments.refnud" } }
      .to raise_error(Permissions::Unknown)
  end

  it "reports which actions are declared, for the route inventory" do
    expect(controller.class.authorization_declared_for?("create")).to be(true)
    expect(controller.class.authorization_declared_for?("show")).to be(true)
    expect(controller.class.authorization_declared_for?("destroy")).to be(false)
  end
end
```

**Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/controllers/authorization_spec.rb`
Expected: FAIL with `uninitialized constant Web`.

**Step 3: Implement**

In `config/application.rb`, after `config.api_only = true`, add:

```ruby
    # The UI (Web::BaseController) needs cookies and a session for CSRF tokens.
    # /v1 never reads the session, so it never sets a cookie. Auth cookies are
    # separate, path-scoped signed cookies per area (design §1).
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, key: "_payhub_web", same_site: :strict,
                                                                secure: Rails.env.production?
```

In `app/lib/api_error.rb`, next to `self.unauthorized`:

```ruby
  sig { params(permission: String).returns(ApiError) }
  def self.forbidden(permission)
    new(type: Type::InvalidRequest, http_status: 403, code: "forbidden",
        message: "Your role does not include #{permission}", param: nil)
  end
```

In `app/lib/metrics.rb` `COUNTERS`, add:

```ruby
      authz_denied: [:area, :permission],
      authz_undeclared: [:controller],
```

```ruby
# app/controllers/concerns/authorization.rb
# typed: true
# frozen_string_literal: true

# Fail-closed authorization for UI controllers (design §3).
#
#   requires_permission "payments.refund", only: :create   # checked BEFORE the action
#   allow_unauthorized only: :show                          # explicit, greppable opt-out
#
# Including controllers implement authorization_area (:merchant / :operator)
# and authorization_role (the signed-in principal's role string). An action
# with neither declaration raises NotDeclared in development and test; the
# route-inventory spec makes that a CI failure before it can reach production.
module Authorization
  extend ActiveSupport::Concern

  class NotDeclared < StandardError; end

  included do
    class_attribute :authorization_rules, instance_writer: false, default: []
    after_action :verify_authorization_declared
  end

  class_methods do
    def requires_permission(permission, only: nil, except: nil)
      raise Permissions::Unknown, "unknown permission #{permission.inspect}" unless Permissions.known?(permission)

      add_authorization_rule(kind: :permission, permission:, only:, except:)
      before_action(**{ only:, except: }.compact) { authorize!(permission) }
    end

    def allow_unauthorized(only: nil, except: nil)
      add_authorization_rule(kind: :public, permission: nil, only:, except:)
      before_action(**{ only:, except: }.compact) { @authorization_checked = true }
    end

    def authorization_declared_for?(action)
      authorization_rules.any? { |rule| rule_applies?(rule, action.to_s) }
    end

    private

    def add_authorization_rule(kind:, permission:, only:, except:)
      self.authorization_rules = authorization_rules + [{
        kind:, permission:,
        only: only && Array(only).map(&:to_s), except: except && Array(except).map(&:to_s)
      }]
    end

    def rule_applies?(rule, action)
      return false if rule[:only] && !rule[:only].include?(action)
      return false if rule[:except]&.include?(action)

      true
    end
  end

  private

  def authorize!(permission)
    @authorization_checked = true
    return if authorization_role && Permissions.granted?(authorization_area, authorization_role, permission)

    record_denial(permission)
    raise ApiError.forbidden(permission)
  end

  def record_denial(permission)
    Metrics.increment(:authz_denied, area: authorization_area.to_s, permission:)
    AuditEvent.record!(
      action: "authorization.denied", result: "denied",
      actor: authorization_actor, actor_label: authorization_actor.try(:email),
      merchant_id: authorization_merchant_id, ip: request.remote_ip, user_agent: request.user_agent,
      request_id: request.request_id,
      metadata: { "permission" => permission, "role" => authorization_role,
                  "route" => "#{controller_path}##{action_name}" }
    )
  end

  def verify_authorization_declared
    return if @authorization_checked

    Metrics.increment(:authz_undeclared, controller: controller_path)
    message = "#{controller_path}##{action_name} ran without requires_permission or allow_unauthorized"
    raise NotDeclared, message unless Rails.env.production?

    Rails.logger.error({ event: "authorization_undeclared", route: "#{controller_path}##{action_name}" }.to_json)
  end

  # Overridden by the area base controllers in phases 1 and 2.
  def authorization_area = raise(NotImplementedError, "#{self.class} must define authorization_area")
  def authorization_role = nil
  def authorization_actor = nil
  def authorization_merchant_id = nil
end
```

```ruby
# app/controllers/web/base_controller.rb
# typed: true
# frozen_string_literal: true

module Web
  # Base for every UI controller (/dashboard, /ops, /demo). Unlike /v1 it has
  # cookies, CSRF protection and HTML layouts. Authorization is declared per
  # action; see Authorization and design §3.
  class BaseController < ActionController::Base
    include Authorization

    protect_from_forgery with: :exception
    layout "web"

    rescue_from ApiError do |e|
      render json: e.to_h(request_id: request.request_id), status: e.http_status
    end
  end
end
```

Denials run in a `before_action`, before any `around_action` that opens a transaction, so a rollback can never drop the audit row. Phase 1 must keep the idempotency `around_action` declared after authorization.

**Step 4: Run it**

Run: `bundle exec rspec spec/controllers/authorization_spec.rb`
Expected: PASS (7 examples). If rspec-rails complains about the missing layout, create an empty `app/views/layouts/web.html.erb` now (Task 12 fills it).

**Step 5: Commit**

```bash
git add config/application.rb app/lib/api_error.rb app/lib/metrics.rb app/controllers/concerns/authorization.rb \
        app/controllers/web/base_controller.rb app/views/layouts/web.html.erb spec/controllers/authorization_spec.rb
git commit -m "Add Web::BaseController with fail-closed, audited permission checks"
```

---

### Task 10: Route inventory spec

**Files:**
- Test: `spec/routing/authorization_inventory_spec.rb`

**Step 1: Write the spec**

```ruby
# spec/routing/authorization_inventory_spec.rb
# frozen_string_literal: true

require "rails_helper"

# The real safeguard behind "a new endpoint without a permission fails CI"
# (design §3). The after_action check only fires when an action is exercised;
# this one covers every route whether or not a spec calls it.
RSpec.describe "Authorization inventory" do
  it "declares requires_permission or allow_unauthorized for every Web action" do
    Rails.application.eager_load!
    undeclared = Rails.application.routes.routes.filter_map do |route|
      controller, action = route.defaults.values_at(:controller, :action)
      next unless controller && action

      klass = "#{controller.camelize}Controller".safe_constantize
      next unless klass && klass < Web::BaseController

      "#{controller}##{action}" unless klass.authorization_declared_for?(action)
    end
    expect(undeclared).to be_empty, "Undeclared UI actions:\n  #{undeclared.join("\n  ")}"
  end
end
```

**Step 2: Run it**

Run: `bundle exec rspec spec/routing/authorization_inventory_spec.rb`
Expected: PASS (no Web routes exist yet). Task 12 adds the first ones.

**Step 3: Commit**

```bash
git add spec/routing/authorization_inventory_spec.rb
git commit -m "Fail CI when any UI route lacks an authorization declaration"
```

---

### Task 11: Forbid role-name checks

**Files:**
- Modify: `bin/check`

**Step 1: Confirm the codebase is clean today**

Run:

```bash
grep -rnE "role ?==|\.(owner|admin|developer|support|viewer|approver)\?" app --include='*.rb' \
  | grep -v "app/lib/permissions.rb" | grep -v "authz-allow-role-check"
```

Expected: no output. If there is output, read each hit before continuing.

**Step 2: Add the gate to `bin/check`, after the permissions step**

```bash
step "authorization (permissions, not role names)"
if grep -rnE "role ?==|\.(owner|admin|developer|support|viewer|approver)\?" app --include='*.rb' \
     | grep -v "app/lib/permissions.rb" | grep -v "authz-allow-role-check"; then
  echo "Check a permission, not a role name (design §3). Role-assignment rules may opt out with # authz-allow-role-check"
  exit 1
fi
```

**Step 3: Run it and commit**

Run: `bin/check`
Expected: all gates green.

```bash
git add bin/check
git commit -m "Fail bin/check on role-name checks outside the permission catalogue"
```

---

### Task 12: Vite Ruby, Vue and three shell pages

**Files:**
- Modify: `Gemfile`, `package.json` (created), `vite.config.ts` (created), `config/vite.json` (created)
- Create: `app/frontend/entrypoints/merchant.ts`, `ops.ts`, `demo.ts`
- Create: `app/frontend/merchant/App.vue`, `app/frontend/ops/App.vue`, `app/frontend/demo/App.vue`
- Create: `app/frontend/env.d.ts`, `tsconfig.json`
- Create: `app/views/layouts/web.html.erb`, `app/views/web/shell.html.erb`
- Create: `app/controllers/dashboard/shell_controller.rb`, `app/controllers/ops/shell_controller.rb`, `app/controllers/demo/shell_controller.rb`
- Modify: `config/routes.rb`
- Test: `spec/requests/web/shells_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/requests/web/shells_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "UI shells" do
  {
    "/dashboard" => "entrypoints/merchant.ts",
    "/dashboard/payments/abc" => "entrypoints/merchant.ts",
    "/ops" => "entrypoints/ops.ts",
    "/demo" => "entrypoints/demo.ts"
  }.each do |path, entry|
    it "serves #{path} with only its own bundle" do
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(entry.sub("entrypoints/", "").delete_suffix(".ts"))
      others = %w[merchant ops demo] - [entry[%r{entrypoints/(\w+)}, 1]]
      others.each { |other| expect(response.body).not_to include("entrypoints/#{other}") }
    end
  end

  it "puts a CSRF token on the page" do
    get "/dashboard"
    expect(response.body).to include('name="csrf-token"')
  end
end
```

Run: `bundle exec rspec spec/requests/web/shells_spec.rb`
Expected: FAIL with a routing error.

**Step 2: Install Vite Ruby and Vue**

```bash
bundle add vite_rails --version "~> 3.0"
bundle exec vite install
npm install vue vue-router @tanstack/vue-query
npm install -D @vitejs/plugin-vue typescript vue-tsc @tailwindcss/vite tailwindcss
rm -f app/frontend/entrypoints/application.js
bin/tapioca gem vite_rails vite_ruby
```

Edit `vite.config.ts`:

```ts
import { defineConfig } from "vite";
import RubyPlugin from "vite-plugin-ruby";
import vue from "@vitejs/plugin-vue";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [RubyPlugin(), vue(), tailwindcss()],
});
```

Check `config/vite.json` has `"sourceCodeDir": "app/frontend"` and, under `test`, `"autoBuild": true`.

Create `tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "jsx": "preserve",
    "noEmit": true,
    "types": ["vite/client"],
    "baseUrl": ".",
    "paths": { "@/*": ["app/frontend/*"] }
  },
  "include": ["app/frontend/**/*.ts", "app/frontend/**/*.vue"]
}
```

Create `app/frontend/env.d.ts`:

```ts
declare module "*.vue" {
  import type { DefineComponent } from "vue";
  const component: DefineComponent<object, object, unknown>;
  export default component;
}
```

**Step 3: Entrypoints and placeholder apps**

```ts
// app/frontend/entrypoints/merchant.ts
import { createApp } from "vue";
import App from "../merchant/App.vue";

createApp(App).mount("#app");
```

Create `ops.ts` and `demo.ts` the same way, importing `../ops/App.vue` and `../demo/App.vue`.

```vue
<!-- app/frontend/merchant/App.vue -->
<template>
  <main class="p-6">
    <h1 class="text-xl font-semibold">PayHub dashboard</h1>
    <p>Phase 1 builds the merchant pages here.</p>
  </main>
</template>
```

Create `ops/App.vue` ("PayHub operations") and `demo/App.vue` ("PayHub demo") the same way.

**Step 4: Layout, shell view, controllers, routes**

```erb
<%# app/views/layouts/web.html.erb %>
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title><%= content_for(:title) || "PayHub" %></title>
    <%= csrf_meta_tags %>
    <%= vite_client_tag %>
    <%= yield :head %>
  </head>
  <body>
    <%= yield %>
  </body>
</html>
```

```erb
<%# app/views/web/shell.html.erb %>
<% content_for :title, title %>
<% content_for :head do %>
  <%= vite_typescript_tag entry %>
<% end %>
<div id="app"></div>
```

```ruby
# app/controllers/dashboard/shell_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  # Serves the empty page the merchant Vue app mounts into. The page itself is
  # public; every /dashboard/api endpoint behind it requires a permission.
  class ShellController < Web::BaseController
    allow_unauthorized only: :show

    def show = render("web/shell", locals: { entry: "merchant", title: "PayHub dashboard" })

    private

    def authorization_area = :merchant
  end
end
```

Create `Ops::ShellController` (`entry: "ops"`, `title: "PayHub operations"`, `authorization_area = :operator`) and `Demo::ShellController` (`entry: "demo"`, `title: "PayHub demo"`, `authorization_area = :merchant`) the same way.

In `config/routes.rb`, at the **end** of the `draw` block, so later `/dashboard/api` routes declared above them win:

```ruby
  # UI shells: the Vue router owns every path below each prefix (design §1).
  # Keep these LAST so /dashboard/api/* and /ops/api/* routes above them match first.
  get "dashboard(/*path)", to: "dashboard/shell#show", format: false
  get "ops(/*path)", to: "ops/shell#show", format: false
  get "demo(/*path)", to: "demo/shell#show", format: false
```

**Step 5: Run and verify by hand**

Run: `bundle exec rspec spec/requests/web/shells_spec.rb spec/routing/authorization_inventory_spec.rb`
Expected: PASS.

Run `bin/vite dev` in one shell and `bin/rails s` in another, then open `http://localhost:3000/dashboard`, `/ops` and `/demo`.
Expected: each shows its heading, and the browser's network tab shows only that area's bundle.

**Step 6: Commit**

```bash
git add Gemfile Gemfile.lock package.json package-lock.json vite.config.ts config/vite.json tsconfig.json \
        bin/vite Procfile.dev app/frontend app/views app/controllers/dashboard app/controllers/ops \
        app/controllers/demo config/routes.rb spec/requests/web sorbet/rbi .gitignore
git commit -m "Serve three Vue bundles from three shell pages with Vite Ruby"
```

---

### Task 13: Frontend quality gates, Docker and CI

**Files:**
- Create: `app/frontend/shared/can.ts`, `app/frontend/shared/can.test.ts`, `vitest.config.ts`, `eslint.config.js`
- Modify: `package.json` (scripts), `bin/check`, `Dockerfile`, `docker-compose.yml`, `.github/workflows/ci.yml`

**Step 1: Write a failing frontend test**

```ts
// app/frontend/shared/can.test.ts
import { describe, expect, it } from "vitest";
import { can } from "./can";

describe("can", () => {
  it("is true only for granted permissions", () => {
    expect(can(["payments.read"], "payments.read")).toBe(true);
    expect(can(["payments.read"], "payments.refund")).toBe(false);
  });
});
```

```bash
npm install -D vitest @vue/test-utils jsdom eslint @eslint/js typescript-eslint eslint-plugin-vue
```

```ts
// vitest.config.ts
import { defineConfig } from "vitest/config";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  plugins: [vue()],
  test: { environment: "jsdom", include: ["app/frontend/**/*.test.ts"] },
});
```

Run: `npx vitest run`
Expected: FAIL, cannot find `./can`.

**Step 2: Implement**

```ts
// app/frontend/shared/can.ts
import type { MerchantPermission, OperatorPermission } from "./permissions";

export type Permission = MerchantPermission | OperatorPermission;

// For hiding UI only. The server enforces every request (design §3).
export function can(granted: readonly Permission[], permission: Permission): boolean {
  return granted.includes(permission);
}
```

Run: `npx vitest run`
Expected: PASS. A misspelt permission in the test would now fail `vue-tsc`, because `permissions.ts` is generated from the Ruby catalogue.

**Step 3: ESLint and scripts**

```js
// eslint.config.js
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import vue from "eslint-plugin-vue";

export default tseslint.config(
  { ignores: ["public/**", "node_modules/**", "tmp/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...vue.configs["flat/recommended"],
  { files: ["**/*.vue"], languageOptions: { parserOptions: { parser: tseslint.parser } } },
);
```

Add to `package.json`:

```json
  "type": "module",
  "scripts": {
    "typecheck": "vue-tsc --noEmit",
    "lint": "eslint app/frontend",
    "test": "vitest run",
    "build": "vite build"
  }
```

**Step 4: Gates in `bin/check`, before the rspec step**

```bash
step "frontend types"
npm run --silent typecheck

step "frontend lint"
npm run --silent lint

step "frontend tests"
npm run --silent test

step "frontend build"
bin/vite build --clear --mode=test
```

Run: `bin/check`
Expected: all gates green.

**Step 5: Node in Docker and compose**

In `Dockerfile`, after the `apt-get` layer:

```dockerfile
# Node for Vite (UI bundles). Copied from the official image to avoid a PPA.
COPY --from=docker.io/library/node:22-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=docker.io/library/node:22-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
```

and, after `RUN bundle install`:

```dockerfile
COPY package.json package-lock.json ./
RUN npm ci
```

In `docker-compose.yml`, add a `vite` service next to `web`, using the same build and volumes as `web`:

```yaml
  vite:
    build: .
    command: bin/vite dev
    environment:
      VITE_RUBY_HOST: 0.0.0.0
    ports:
      - "3036:3036"
    volumes:
      - .:/rails
      - /rails/node_modules
```

and add `VITE_RUBY_HOST: vite` to the `web` service's environment.

**Step 6: CI**

In `.github/workflows/ci.yml`, in the job that runs `bin/check`, after `ruby/setup-ruby`:

```yaml
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
```

**Step 7: Commit**

```bash
git add app/frontend/shared vitest.config.ts eslint.config.js package.json package-lock.json bin/check \
        Dockerfile docker-compose.yml .github/workflows/ci.yml
git commit -m "Add frontend type, lint, test and build gates to bin/check, Docker and CI"
```

---

### Task 14: Action Mailer and MailCatcher

**Files:**
- Modify: `config/application.rb`, `config/environments/development.rb`, `config/environments/test.rb`, `config/environments/production.rb`, `docker-compose.yml`
- Create: `app/mailers/application_mailer.rb`, `app/mailers/system_mailer.rb`, `app/views/layouts/mailer.text.erb`, `app/views/system_mailer/smoke.text.erb`, `lib/tasks/mail.rake`
- Test: `spec/mailers/system_mailer_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/mailers/system_mailer_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe SystemMailer do
  it "delivers a smoke-test email through the configured delivery method" do
    expect { described_class.smoke("ops@example.com").deliver_now }
      .to change(ActionMailer::Base.deliveries, :size).by(1)
    expect(ActionMailer::Base.deliveries.last.to).to eq(["ops@example.com"])
  end
end
```

Run: `bundle exec rspec spec/mailers/system_mailer_spec.rb`
Expected: FAIL with `uninitialized constant SystemMailer`.

**Step 2: Re-enable and configure Action Mailer**

In `config/application.rb`, uncomment `require "action_mailer/railtie"`.

`config/environments/development.rb`:

```ruby
  # All mail goes to MailCatcher (docker compose service); read it at http://localhost:1080.
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = { address: ENV.fetch("SMTP_HOST", "localhost"),
                                         port: Integer(ENV.fetch("SMTP_PORT", "1025")) }
  config.action_mailer.default_url_options = { host: "localhost", port: 3000 }
  config.action_mailer.raise_delivery_errors = true
```

`config/environments/test.rb`:

```ruby
  config.action_mailer.delivery_method = :test
  config.action_mailer.default_url_options = { host: "www.example.com" }
```

`config/environments/production.rb`:

```ruby
  # Real SMTP credentials are out of scope for this project (design §5).
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = { address: ENV.fetch("SMTP_HOST", "localhost"),
                                         port: Integer(ENV.fetch("SMTP_PORT", "587")),
                                         user_name: ENV["SMTP_USERNAME"], password: ENV["SMTP_PASSWORD"] }.compact
```

**Step 3: Mailers**

```ruby
# app/mailers/application_mailer.rb
# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "PayHub <no-reply@payhub.local>")
  layout "mailer"
end
```

```ruby
# app/mailers/system_mailer.rb
# frozen_string_literal: true

# Proves the mail path end to end. Real mailers (invitations, security alerts,
# proposals awaiting approval) arrive in phases 1 and 2.
class SystemMailer < ApplicationMailer
  def smoke(to)
    mail(to:, subject: "PayHub mail is working")
  end
end
```

`app/views/layouts/mailer.text.erb`: `<%= yield %>`

`app/views/system_mailer/smoke.text.erb`: `If you can read this in MailCatcher, PayHub can send email.`

```ruby
# lib/tasks/mail.rake
# frozen_string_literal: true

namespace :mail do
  desc "Send a smoke-test email (open http://localhost:1080 to read it)"
  task :smoke, [:to] => :environment do |_t, args|
    SystemMailer.smoke(args[:to] || "dev@payhub.local").deliver_now
    puts "Sent. Open http://localhost:1080"
  end
end
```

**Step 4: MailCatcher in compose**

```yaml
  mailcatcher:
    image: sj26/mailcatcher:latest
    ports:
      - "1080:1080"   # web inbox
      - "1025:1025"   # SMTP
```

Add `SMTP_HOST: mailcatcher` and `SMTP_PORT: "1025"` to the `web` and `worker` environments. If the image misbehaves, `axllent/mailpit` is a drop-in replacement (SMTP 1025, inbox on 8025).

**Step 5: Verify and commit**

Run: `bundle exec rspec spec/mailers/system_mailer_spec.rb`
Expected: PASS.

Run: `docker compose up -d mailcatcher && bin/rails "mail:smoke[me@example.com]"`, then open `http://localhost:1080`.
Expected: the email is in the inbox.

```bash
git add config app/mailers app/views/layouts/mailer.text.erb app/views/system_mailer lib/tasks/mail.rake \
        spec/mailers docker-compose.yml
git commit -m "Send real email, caught locally by MailCatcher"
```

---

### Task 15: Record the decisions and update the README

**Files:**
- Modify: `DECISIONS.md` (append #21–#24), `README.md` ("Run it" section), `RUNBOOK.md` (mention `psp_calls`)

**Step 1: Append to DECISIONS.md**, in the existing format (Decision / Rejected / Reason):

- **#21 A UI, kept beside the API rather than in it.** Decision: three Vue bundles served by Vite Ruby from the same Rails app, behind `Web::BaseController`; `/v1` unchanged. Rejected: a separate SPA calling `/v1` over CORS. Reason: same-origin cookie sessions keep secret keys out of the browser, and the assignment's "no UI" scope is preserved for the API itself.
- **#22 Test mode is a twin merchant.** Decision: each live merchant has one test-mode twin; `sk_test_` keys open it. Rejected: a `livemode` column on payments, refunds, captures, ledger accounts and events. Reason: every query is already scoped by merchant, so separation comes from existing scoping, and the ledger, chaos run and simulation are untouched.
- **#23 Operators change money only with two people.** Decision: manual exits from `unknown` and ledger corrections are proposals approved by a different operator. Rejected: a single operator transition with a reason (the current runbook). Reason: segregation of duties is the baseline for manual money movement (research report), and it is enforceable by a CHECK constraint.
- **#24 Permissions are a catalogue in code, checked per action, verified in CI.** Decision: `resource.verb` permissions in `app/lib/permissions.rb`; `requires_permission` on every action; a route inventory and an independent matrix in CI. Rejected: Pundit/CanCanCan, a policy engine, permissions in the database. Reason: nine fixed roles do not need them; each deferred option has a written trigger in design §3.

**Step 2: README.** In "Run it", add that compose now also starts `vite` and `mailcatcher`, the three UI URLs, the MailCatcher inbox URL, and that the seed prints a live **and** a test key.

**Step 3: RUNBOOK.** In the stuck-payment section, add one line: "`PspCall.where(psp_reference: p.psp_reference).order(:sent_at)` shows every call we made for this payment, including the one that timed out."

**Step 4: Commit**

```bash
git add DECISIONS.md README.md RUNBOOK.md
git commit -m "Record decisions #21-#24 and document the UI dev setup"
```

---

### Task 16: Full verification

**Step 1:** Run `bin/check`. Expected: every gate green, ending with `All gates green.`

**Step 2:** Run the stack and the chaos run, exactly as CI does:

```bash
docker compose up -d --build --wait
docker compose exec -T web bin/rails db:prepare db:seed
docker compose exec -T web bin/rails "chaos:run[30]"
```

Expected: the chaos run reports every invariant holding. Then check `docker compose exec -T web bin/rails runner 'p PspCall.group(:outcome).count'` shows `ok` rows and, usually, some `timeout` rows.

**Step 3:** Open `http://localhost:3000/dashboard`, `/ops`, `/demo` and `http://localhost:1080`.

**Step 4:** Use @superpowers:verification-before-completion, then @superpowers:requesting-code-review before opening the PR.

---

## After this plan: phases 1–3

Each phase gets its own plan file, written after this one merges, so it can reference real code.

| Plan | Main tasks |
|---|---|
| `…-ui-phase-1-merchant.md` | `merchant_users`, `sessions` (Rails 8 auth generator, polymorphic), `recovery_codes`; TOTP enrolment and login; lockout and idle timeout; step-up; invitations and `InvitationMailer`; `Dashboard::Api::BaseController` (area, role, tenant scoping, twin switch); every merchant endpoint and page in design §4 with `requires_permission` and `can` flags; `useLiveQuery` and **USER WRITES `pollIntervalFor`**; security history page; audit retention job; Playwright flow 1. |
| `…-ui-phase-2-operator.md` | `operators` and their sessions; `operator_proposals` with the no-self-approval CHECK, row lock and immutable payload; **USER WRITES `approvable_by?`**; applying proposals through `Payment#transition!` and `Ledger`; queue, search, superset detail with `psp_calls`; view-as-merchant; `OperatorMailer`; Playwright flow 2. |
| `…-ui-phase-3-demo.md` | Deterministic magic tokens in both simulators; demo endpoints and IP throttle; state-machine diagram; chaos run summary endpoint; ledger summary; reset; Playwright flow 3. |
