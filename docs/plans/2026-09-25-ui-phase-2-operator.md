# PayHub UI Phase 2: Operator Console Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** PayHub staff sign in to `/ops` with password + TOTP and can:
- work a needs-attention queue;
- search and inspect any payment, including our own PSP calls and inbound webhooks;
- poll the PSP and redeliver events;
- propose manual payment transitions and ledger corrections that a **different** operator must approve;
- see PSP circuit state;
- review reconciliation breaks;
- view a merchant's dashboard read-only;
- manage operators and export who holds which role;
- read the operator audit stream.

**Architecture:** Operators are a separate model and a separate cookie (`_payhub_ops`, path `/ops`), reusing the polymorphic `sessions` table, `TwoFactorPrincipal`, `SignIn` and `TwoFactorSessionActions` from Phase 1. `Ops::Api::BaseController` reads across merchants, so tenant scoping is deliberately absent there. Every write is audited with the operator as actor. Money changes go through `operator_proposals`: the database refuses self-approval, the row is locked while it is decided, and its payload cannot be edited after submission. An approved proposal is applied through `Payment#transition!` or `Ledger.record!`, never by editing rows. Impersonation reuses the Phase 1 dashboard read endpoints under `/ops/api/as/:merchant_id`, with a narrowed `permission_granted?` that allows only `*.read`.

**Tech Stack:** as Phase 1. No new gems.

**Design sources:** [UI design](2026-09-25-ui-design.md) §2 (`operators`, `operator_proposals`, `sessions` impersonation columns), §3 (operator permissions, layer 4), §4 Operator table, §5 `OperatorMailer`; [use cases](2026-09-25-ui-use-cases.md) O-01 to O-15; `reports/RBAC implementation patterns.md` (maker-checker); DECISIONS #10, #13, #17, #18, #23.

**Prerequisite:** Phase 1 merged. This plan names Phase 1's classes directly (`TwoFactorPrincipal`, `SignIn`, `TwoFactorSessionActions`, `IdempotentAction`, `Dashboard::Api::*`, `PaymentTimeline`, `MemberSerializer`, `useLiveQuery`, `createClient`).

---

## Conventions

Same as Phase 1 (see its "Conventions" section). In particular:
- re-dump `structure.sql` from development;
- `type: :request` on request specs;
- `# authz-allow-role-check` on role-assignment rules;
- `bin/check && git commit`, never a piped `bin/check`;
- **USER WRITES** steps stop for the user.

**Idempotency on operator writes.** `IdempotencyGuard` is keyed by merchant, and operators act across merchants. Operator writes are made safe by state instead:
- Approving locks the proposal and requires `state = pending`.
- Polling is naturally repeatable.
- Redeliver requires `state = dead`.
- Creating a proposal takes a client-generated `client_token` (unique index), so a retried submit returns the same proposal.

Record this in DECISIONS #26 (Task 17).

---

### Task 0: Branch

```bash
git checkout master && git pull && git checkout -b feature/ui-phase-2-operator
```

---

### Task 1: Operators, proposals, impersonation columns, review columns

**Files:**
- Create: `db/migrate/20260927000001_create_operators_and_proposals.rb`
- Create: `app/models/operator.rb`, `app/models/operator_proposal.rb`
- Modify: `app/models/session.rb` (impersonation helpers), `app/models/settlement_line.rb`
- Test: `spec/models/operator_spec.rb`, `spec/models/operator_proposal_spec.rb`, `spec/factories/operators.rb`, `spec/factories/operator_proposals.rb`

**Step 1: Failing model specs**

```ruby
# spec/models/operator_proposal_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorProposal do
  let(:maker) { create(:operator, role: "ops") }
  let(:checker) { create(:operator, role: "approver") }
  let(:payment) { create(:payment).tap { |p| p.update_columns(state: "unknown") } } # rubocop:disable Rails/SkipsModelValidations

  it "refuses self-approval in the database" do
    proposal = create(:operator_proposal, payment:, proposed_by: maker)
    expect { described_class.where(id: proposal.id).update_all(decided_by_id: maker.id, state: "rejected") }
      .to raise_error(ActiveRecord::StatementInvalid, /chk_operator_proposals_not_self/)
  end

  it "never lets the payload change after submission, even bypassing Rails" do
    proposal = create(:operator_proposal, payment:, proposed_by: maker)
    expect { described_class.where(id: proposal.id).update_all(payload: { "to_state" => "authorized" }) }
      .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
  end

  it "accepts only transitions out of unknown that the state machine allows" do
    expect(build(:operator_proposal, payment:, proposed_by: maker, payload: { "to_state" => "captured" })).not_to be_valid
    expect(build(:operator_proposal, payment:, proposed_by: maker, payload: { "to_state" => "failed" })).to be_valid
  end

  it "accepts a ledger correction only when its legs balance" do
    unbalanced = { "currency" => "EUR", "legs" => [{ "account_kind" => "merchant_payable", "direction" => "credit", "amount_minor" => 5 }] }
    expect(build(:operator_proposal, :ledger_correction, payment:, proposed_by: maker, payload: unbalanced)).not_to be_valid
  end

  it "requires a reason code and a case reference" do
    expect(build(:operator_proposal, payment:, proposed_by: maker, reason_code: nil)).not_to be_valid
    expect(build(:operator_proposal, payment:, proposed_by: maker, case_reference: "")).not_to be_valid
  end
end
```

`spec/models/operator_spec.rb` mirrors the `MerchantUser` spec's 2FA, lockout and encryption examples. Add:
- the role CHECK rejects `superuser`;
- `Operator.invite!` returns a token and refuses nothing (every operator role is invitable by an operator admin).

Run both. Expected: FAIL.

**Step 2: Migration**

```ruby
# db/migrate/20260927000001_create_operators_and_proposals.rb
class CreateOperatorsAndProposals < ActiveRecord::Migration[8.1]
  def up
    create_table :operators, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :email, null: false
      t.string :name
      t.string :password_digest
      t.string :role, null: false
      t.text :otp_secret
      t.datetime :otp_enabled_at
      t.bigint :otp_last_used_step
      t.integer :failed_attempts, null: false, default: 0
      t.datetime :locked_until
      t.uuid :invited_by_id
      t.string :invitation_digest
      t.datetime :invitation_expires_at
      t.datetime :accepted_at
      t.datetime :disabled_at
      t.timestamps
    end
    add_index :operators, "lower(email)", unique: true, name: "idx_operators_email"
    add_index :operators, :invitation_digest, unique: true, where: "invitation_digest IS NOT NULL"
    add_check_constraint :operators, "role IN ('support', 'ops', 'approver', 'admin')", name: "chk_operators_role"
    add_foreign_key :operators, :operators, column: :invited_by_id

    create_table :operator_proposals, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :kind, null: false
      t.references :payment, type: :uuid, null: false, foreign_key: true
      t.jsonb :payload, null: false
      t.string :reason_code, null: false
      t.text :reason_text, null: false
      t.string :case_reference, null: false
      t.string :client_token, null: false         # retried submit → same proposal
      t.references :proposed_by, type: :uuid, null: false, foreign_key: { to_table: :operators }
      t.string :state, null: false, default: "pending"
      t.references :decided_by, type: :uuid, foreign_key: { to_table: :operators }
      t.datetime :decided_at
      t.text :decision_note
      t.datetime :applied_at
      t.uuid :applied_transfer_id                 # ledger corrections: the transfer we posted
      t.string :error
      t.timestamps
    end
    add_index :operator_proposals, :client_token, unique: true
    add_index :operator_proposals, %i[state created_at]
    add_check_constraint :operator_proposals, "kind IN ('payment_transition', 'ledger_correction')", name: "chk_operator_proposals_kind"
    add_check_constraint :operator_proposals, "state IN ('pending', 'withdrawn', 'rejected', 'applied', 'failed')",
                         name: "chk_operator_proposals_state"
    add_check_constraint :operator_proposals, "decided_by_id IS NULL OR decided_by_id <> proposed_by_id",
                         name: "chk_operator_proposals_not_self"
    add_check_constraint :operator_proposals, "(state = 'pending') = (decided_at IS NULL) OR state = 'withdrawn'",
                         name: "chk_operator_proposals_decided_shape"

    # An approver approves exactly what they read (design §3, layer 4).
    execute <<~SQL
      CREATE FUNCTION operator_proposal_payload_immutable() RETURNS trigger AS $$
      BEGIN
        IF NEW.payload IS DISTINCT FROM OLD.payload OR NEW.kind IS DISTINCT FROM OLD.kind
           OR NEW.payment_id IS DISTINCT FROM OLD.payment_id OR NEW.proposed_by_id IS DISTINCT FROM OLD.proposed_by_id THEN
          RAISE EXCEPTION 'operator_proposals payload is immutable; withdraw and resubmit';
        END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER trg_operator_proposals_immutable BEFORE UPDATE ON operator_proposals
        FOR EACH ROW EXECUTE FUNCTION operator_proposal_payload_immutable();
    SQL

    change_table :sessions, bulk: true do |t|
      t.uuid :impersonating_merchant_id
      t.string :impersonation_case_ref
      t.datetime :impersonation_expires_at
    end
    add_foreign_key :sessions, :merchants, column: :impersonating_merchant_id

    change_table :settlement_lines, bulk: true do |t|
      t.datetime :reviewed_at
      t.uuid :reviewed_by_id
      t.text :review_note
    end
    add_foreign_key :settlement_lines, :operators, column: :reviewed_by_id
  end

  def down
    remove_foreign_key :settlement_lines, column: :reviewed_by_id
    change_table(:settlement_lines, bulk: true) { |t| t.remove :reviewed_at, :reviewed_by_id, :review_note }
    remove_foreign_key :sessions, column: :impersonating_merchant_id
    change_table(:sessions, bulk: true) { |t| t.remove :impersonating_merchant_id, :impersonation_case_ref, :impersonation_expires_at }
    drop_table :operator_proposals
    execute "DROP FUNCTION operator_proposal_payload_immutable()"
    drop_table :operators
  end
end
```

Before writing the migration, check whether `settlement_lines` has an update trigger. If it is append-only, put the review in a separate `settlement_line_reviews` table instead of these columns, and adjust Task 9.

**Step 3: Models**

```ruby
# app/models/operator.rb
# typed: true
# frozen_string_literal: true

# PayHub staff. Separate from MerchantUser: different cookie, different
# permissions, and nothing a merchant can ever grant.
class Operator < ApplicationRecord
  include TwoFactorPrincipal

  ROLES = %w[support ops approver admin].freeze
  INVITATION_TTL = 3.days

  belongs_to :invited_by, class_name: "Operator", optional: true
  validates :role, inclusion: { in: ROLES }

  def self.invite!(email:, role:, invited_by:)
    raise ArgumentError, "unknown operator role #{role.inspect}" unless ROLES.include?(role)

    token = SecureRandom.urlsafe_base64(32)
    op = create!(email:, role:, invited_by:, invitation_digest: Digest::SHA256.hexdigest(token),
                 invitation_expires_at: INVITATION_TTL.from_now, otp_secret: Otp.generate_secret)
    [op, token]
  end

  def self.find_by_invitation_token(token)
    return nil if token.blank?

    where(accepted_at: nil, disabled_at: nil).where("invitation_expires_at > ?", Time.current)
                                              .find_by(invitation_digest: Digest::SHA256.hexdigest(token))
  end
end
```

Phase 1's `MerchantUser.find_by_invitation_token` and this one are identical; move the shared body into `TwoFactorPrincipal` as a class method (`class_methods do … end`). Keep `invite!` per model: the role rules differ.

```ruby
# app/models/operator_proposal.rb
# typed: true
# frozen_string_literal: true

# Maker-checker for manual money changes (DECISIONS #23). The database
# enforces the invariants (no self-approval, immutable payload); this model
# validates the payload's shape on the way in.
class OperatorProposal < ApplicationRecord
  KINDS = %w[payment_transition ledger_correction].freeze
  STATES = %w[pending withdrawn rejected applied failed].freeze
  REASON_CODES = %w[psp_confirmed_outcome psp_unreachable_timeout duplicate_booking ledger_error other].freeze
  # Operators move payments only out of `unknown` (DECISIONS #10). The other
  # stuck state, `pending`, is left to the worker and the sweeper.
  ALLOWED_TRANSITIONS = { "unknown" => %w[authorized failed] }.freeze

  belongs_to :payment
  belongs_to :proposed_by, class_name: "Operator"
  belongs_to :decided_by, class_name: "Operator", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :reason_code, inclusion: { in: REASON_CODES }
  validates :reason_text, :case_reference, :client_token, presence: true
  validate :payload_shape, on: :create

  scope :open, -> { where(state: "pending") }

  # TODO(user): Task 10.
  def approvable_by?(operator)
    raise NotImplementedError
  end

  def legs
    Array(payload["legs"]).map do |l|
      Ledger::Leg.new(account_kind: l.fetch("account_kind"), direction: l.fetch("direction"), amount_minor: Integer(l.fetch("amount_minor")))
    end
  end

  private

  def payload_shape
    kind == "ledger_correction" ? ledger_correction_shape : transition_shape
  end

  def transition_shape
    from = payment&.state
    to = payload["to_state"]
    return if ALLOWED_TRANSITIONS.fetch(from.to_s, []).include?(to)

    errors.add(:payload, "can move a #{from} payment only to #{ALLOWED_TRANSITIONS.fetch(from.to_s, []).join(' or ').presence || 'nothing'}")
  end

  def ledger_correction_shape
    unless Currency.supported?(payload["currency"].to_s)
      errors.add(:payload, "currency is not supported")
      return
    end
    parsed = legs
    net = parsed.sum { |l| l.direction == "credit" ? l.amount_minor : -l.amount_minor }
    errors.add(:payload, "legs must net to zero and number at least two") unless parsed.size >= 2 && net.zero?
    errors.add(:payload, "unknown account kind") unless parsed.all? { |l| LedgerAccount::KINDS.include?(l.account_kind) }
    errors.add(:payload, "amounts must be positive") unless parsed.all? { |l| l.amount_minor.positive? }
  rescue KeyError, ArgumentError, TypeError
    errors.add(:payload, "legs need account_kind, direction and a positive integer amount_minor")
  end
end
```

Check `LedgerAccount::KINDS` exists (the CHECK lists psp_receivable, merchant_payable, refunds_reserved, refunds_paid, psp_payouts, psp_fees). If the constant has another name, use it.

Add to `Session`:

```ruby
  IMPERSONATION_TTL = 30.minutes

  def impersonating? = impersonating_merchant_id.present? && impersonation_expires_at&.future?

  def start_impersonation!(merchant_id:, case_ref:)
    update!(impersonating_merchant_id: merchant_id, impersonation_case_ref: case_ref,
            impersonation_expires_at: IMPERSONATION_TTL.from_now)
  end

  def stop_impersonation!
    update!(impersonating_merchant_id: nil, impersonation_case_ref: nil, impersonation_expires_at: nil)
  end
```

Factories: `:operator` (like `:merchant_user`, `role { "support" }`). `:operator_proposal` has kind `payment_transition`, payload `{ "to_state" => "failed" }`, reason_code `psp_confirmed_outcome`, reason_text, case_reference `OPS-1`, and a unique `client_token`. Trait `:ledger_correction` has balanced legs of 100 minor units between `merchant_payable` and `psp_receivable`.

**Step 4: Migrate, run, commit**

```bash
bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate && bundle exec rspec spec/models
bin/rails db:schema:dump && bin/tapioca dsl
bin/check && git add db app/models spec sorbet/rbi && \
  git commit -m "Add operators, maker-checker proposals and impersonation and review columns"
```

`approvable_by?` raises `NotImplementedError` until Task 10; no spec calls it before then.

---

### Task 2: Ops API base, operator sign-in and enrolment

**Files:**
- Create: `app/controllers/ops/api/base_controller.rb`, `sessions_controller.rb`, `me_controller.rb`, `invitations_controller.rb`, `otp_controller.rb` (under `app/controllers/ops/api/`)
- Create: `app/presenters/operator_me_presenter.rb`, `app/mailers/operator_mailer.rb`
- Modify: `config/routes.rb`
- Test: `spec/support/ops_helpers.rb`, `spec/requests/ops/api/sessions_spec.rb`, `spec/requests/ops/api/me_spec.rb`

**Step 1: Base controller**

```ruby
# app/controllers/ops/api/base_controller.rb
# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # Every /ops/api controller. Operators read ACROSS merchants, so there is
    # no tenant scoping here; the permission layer and the audit log carry the
    # weight, and every write names the operator.
    class BaseController < Web::BaseController
      COOKIE = :_payhub_ops
      IDLE_TIMEOUT = 10.minutes # design §2: stricter than merchants

      wrap_parameters false
      before_action :require_session!

      rescue_from ActiveRecord::RecordNotFound do
        render_api_error(ApiError.not_found("resource"))
      end
      rescue_from ActionController::ParameterMissing do |e|
        render_api_error(ApiError.invalid_request("Missing parameter: #{e.param}", param: e.param.to_s))
      end
      rescue_from PspAdapter::Unavailable, PspAdapter::TimedOut do |e|
        render_api_error(ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 503, code: "psp_unavailable",
                                      message: e.message, retriable: true))
      end

      private

      def require_session!
        row = Session.find_by(id: cookies.signed[COOKIE], principal_type: "Operator")
        op = row&.principal
        raise ApiError.unauthenticated unless row&.active?(idle: IDLE_TIMEOUT) && op.is_a?(Operator) && op.active?

        @current_session = row
        @current_user = op
        row.touch_activity!
      end

      def current_session = T.must(@current_session)
      def current_user = T.must(@current_user)

      def authorization_area = :operator
      def authorization_role = @current_user&.role
      def authorization_actor = @current_user
      def step_up_fresh? = @current_session&.stepped_up? || false

      def audit!(action, target: nil, merchant_id: nil, on_behalf_of_merchant_id: nil, result: "success", metadata: {})
        AuditEvent.record!(action:, result:, actor: current_user, actor_label: current_user.email, merchant_id:,
                           on_behalf_of_merchant_id:, target:, ip: request.remote_ip, user_agent: request.user_agent,
                           request_id: request.request_id, metadata:)
      end

      def set_session_cookie(session_row)
        cookies.signed[COOKIE] = { value: session_row.id, httponly: true, same_site: :strict,
                                   secure: Rails.env.production?, path: "/ops" }
      end

      # Every operator write that concerns a case must say which one.
      def reason! = params.require(:reason).to_s.strip.presence || raise(ApiError.validation("reason" => ["is required"]))
    end
  end
end
```

**Step 2: Sessions, me, invitations, OTP**

`Ops::Api::SessionsController` is Phase 1's `Dashboard::Api::SessionsController` with:
- `principal_scope = Operator`
- `session_cookie_name = COOKIE`
- `session_cookie_path = "/ops"`
- `session_payload = OperatorMePresenter.call(op, session_row)`

`OperatorMePresenter` returns user, `permissions: Permissions.for(:operator, role)`, and `impersonating: { merchant_id, merchant_name, case_ref, expires_at } | nil`.

`Ops::Api::InvitationsController` and `OtpController` copy Phase 1's, with these changes:
- `create` needs `ops.operators.manage` and calls `Operator.invite!`;
- mail goes through `OperatorMailer.invite`;
- the cookie path is `/ops`;
- `find_by_invitation_token` comes from `TwoFactorPrincipal`.

If the two copies differ only in the model, cookie and presenter, extract a `TwoFactorEnrolmentActions` concern the way `TwoFactorSessionActions` was extracted in Phase 1. Do that extraction, with Phase 1's controllers as the regression suite.

```ruby
# app/mailers/operator_mailer.rb
# frozen_string_literal: true

class OperatorMailer < ApplicationMailer
  def invite(operator, token)
    options = Rails.application.config.action_mailer.default_url_options || {}
    base = "#{options[:protocol] || 'http'}://#{options.fetch(:host, 'localhost')}#{":#{options[:port]}" if options[:port]}"
    @url = "#{base}/ops/invitations/#{token}"
    @role = operator.role
    mail(to: operator.email, subject: "Your PayHub operator account")
  end

  def proposal_waiting(proposal, approver)
    @proposal = proposal
    mail(to: approver.email, subject: "Proposal waiting for approval: #{proposal.case_reference}")
  end
end
```

Move the `base` URL expression into `ApplicationMailer#app_url(path)` and use it from `InvitationMailer` too.

Routes:

```ruby
  namespace :ops do
    namespace :api, defaults: { format: :json } do
      resource :session, only: %i[create destroy] do
        post :otp
        post :recovery
        post :step_up
      end
      get "me", to: "me#show"
      resources :invitations, only: %i[show], param: :token do
        post :accept, on: :member
      end
      get "otp/setup", to: "otp#setup"
      post "otp/confirm", to: "otp#confirm"
    end
  end
```

**Step 3: Specs**

`spec/support/ops_helpers.rb`: `sign_in_operator(op, stepped_up: false)`, the same shape as `sign_in_as`, using `:_payhub_ops`.

Sessions spec:
- The full password → code → session flow.
- A merchant cookie does **not** authenticate `/ops/api/me` (sign in a merchant user, request `/ops/api/me`, expect 401).
- The idle timeout is 10 minutes.
- An operator admin invites (step-up needed), and the invitee enrols.

**Step 4: Bootstrap task**

```ruby
# lib/tasks/operators.rake
# frozen_string_literal: true

namespace :operators do
  desc "Invite an operator (prints the link; also emailed). The first admin is created this way."
  task :invite, %i[email role] => :environment do |_t, args|
    op, token = Operator.invite!(email: args.fetch(:email), role: args.fetch(:role, "support"), invited_by: nil)
    OperatorMailer.invite(op, token).deliver_now
    puts "Invitation for #{op.email} (#{op.role}): http://localhost:3000/ops/invitations/#{token}"
  end
end
```

```bash
bin/check && git add app config lib/tasks/operators.rake spec && \
  git commit -m "Add operator sign-in, enrolment and a separate ops session cookie"
```

---

### Task 3: Needs-attention queue

**Files:**
- Create: `app/controllers/ops/api/queue_controller.rb`, `app/services/ops_queue.rb`
- Test: `spec/services/ops_queue_spec.rb`, `spec/requests/ops/api/queue_spec.rb`

```ruby
# app/services/ops_queue.rb
# typed: true
# frozen_string_literal: true

# O-01: exceptions go to a queue, never to a silent fix. Oldest first.
module OpsQueue
  LIMIT = 50

  def self.call
    {
      "unknown_payments" => Payment.where(state: "unknown").order(:updated_at).limit(LIMIT).includes(:merchant).map do |p|
        { "id" => p.id, "merchant" => p.merchant.name, "psp_name" => p.psp_name, "psp_reference" => p.psp_reference,
          "amount_minor" => p.amount_minor, "currency" => p.currency, "stuck_since" => p.updated_at.utc.iso8601,
          "check_attempts" => p.check_attempts }
      end,
      "dead_events" => OutboundEvent.where(state: "dead").order(:updated_at).limit(LIMIT).includes(:merchant).map do |e|
        { "id" => e.id, "merchant" => e.merchant.name, "type" => e.event_type, "payment_id" => e.payment_id,
          "last_error" => e.last_error, "dead_since" => e.updated_at.utc.iso8601 }
      end,
      "reconciliation_breaks" => SettlementLine.where(status: %w[unmatched mismatch], reviewed_at: nil).count,
      "open_proposals" => OperatorProposal.open.count
    }
  end
end
```

Check `payments.check_attempts` exists (the sweeper increments it). `Payment.where(state: "unknown")` needs an index. Check `db/structure.sql` for one on `(state, …)`. The sweeper's `DUE_AT_SQL` expression index is partial on stuck states and may serve. Run `EXPLAIN` in a console against the 1M-row perf seed; if it is a sequential scan, add a partial index `ON payments (updated_at) WHERE state = 'unknown'` in this task's migration.

The controller is `requires_permission "ops.queue.read", only: :show` and renders `OpsQueue.call`. Route: `get "queue", to: "queue#show"`.

Spec:
- Ordering (oldest stuck first) and all four sections present.
- A `support` operator can read it.
- A merchant session cannot (401).

```bash
bin/check && git add app config spec db && git commit -m "Add the operator needs-attention queue"
```

---

### Task 4: Search and the superset payment detail, with Poll PSP now

**Files:**
- Create: `app/controllers/ops/api/payments_controller.rb`, `app/services/ops_payment_detail.rb`
- Modify: `app/lib/psp_call_log.rb` (body size cap, from the Phase 0 review)
- Test: `spec/requests/ops/api/payments_spec.rb`, `spec/lib/psp_call_log_spec.rb` (add)

**Step 1: Search**

`GET payments?q=` matches, in order:
- an exact payment id (UUID format);
- an exact `psp_reference` (`ph_…`);
- a merchant name `ILIKE` prefix, returning that merchant's 50 latest payments.

Never do a `%q%` scan over payments.

```ruby
      def index
        q = params[:q].to_s.strip
        scope =
          if q.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) then Payment.where(id: q)
          elsif q.start_with?("ph_") then Payment.where(psp_reference: q)
          elsif q.length >= 2 then Payment.where(merchant_id: Merchant.where("name ILIKE ?", "#{Merchant.sanitize_sql_like(q)}%").select(:id))
          else Payment.none
          end
        rows = scope.includes(:merchant).order(created_at: :desc).limit(50)
        render json: { "data" => rows.map { |p| PaymentSerializer.call(p).merge("merchant" => p.merchant.name, "livemode" => p.merchant.livemode) } }
      end
```

**Step 2: Detail superset (O-03)**

```ruby
# app/services/ops_payment_detail.rb
# typed: true
# frozen_string_literal: true

# What the merchant sees, plus what only we have: every call we made to the
# PSP (psp_calls, redacted), every webhook the PSP sent (inbound_events,
# signature valid or not), and the raw ledger entries.
module OpsPaymentDetail
  def self.call(payment)
    PaymentSerializer.call(payment).merge(
      "merchant" => { "id" => payment.merchant_id, "name" => payment.merchant.name, "livemode" => payment.merchant.livemode },
      "timeline" => PaymentTimeline.call(payment),
      "psp_calls" => PspCall.where(psp_name: payment.psp_name, psp_reference: payment.psp_reference).order(:sent_at).map do |c|
        c.slice(:operation, :http_status, :outcome, :duration_ms, :request_redacted, :response_redacted)
         .merge("sent_at" => c.sent_at.utc.iso8601(3))
      end,
      "inbound_events" => InboundEvent.where(psp_name: payment.psp_name, psp_reference: payment.psp_reference).order(:received_at).map do |e|
        e.slice(:event_type, :signature_valid, :error, :payload)
         .merge("received_at" => e.received_at.utc.iso8601(3), "processed_at" => e.processed_at&.utc&.iso8601(3))
      end,
      "proposals" => OperatorProposal.where(payment:).order(:created_at).map { |pr| ProposalSerializer.call(pr) }
    )
  end
end
```

`inbound_events.payload` is the PSP's body as received. Pass it through `PspCallRedactor.redact` before rendering. It is stored unredacted today, and an operator screen is not the place to show a token.

**Step 3: Poll now (O-04)**

```ruby
      requires_permission "ops.payments.poll", only: :poll

      def poll
        payment = Payment.find(params[:id])
        StuckPaymentSweeperJob.poll_now(payment)
        audit!("payment.polled", target: payment, merchant_id: payment.merchant_id)
        render json: OpsPaymentDetail.call(payment.reload)
      end
```

`poll_now` calls the PSP synchronously; an open circuit raises `PspCircuit::Open` (an `Unavailable`), which the base controller answers with 503 `psp_unavailable`. Say so in the UI.

**Step 4: psp_calls body cap (Phase 0 review, minor #14)**

In `PspCallLog.record`, truncate any redacted string value longer than 16 KB to its first 16 KB plus `"…[truncated]"`. Add a `PspCallRedactor.cap(value, bytes: 16_384)` walker and a spec: a 100 KB HTML 502 body is stored at most 16.5 KB.

Routes:

```ruby
      resources :payments, only: %i[index show] do
        post :poll, on: :member
      end
```

Specs:
- Search by id, by reference and by merchant prefix.
- The detail includes `psp_calls` with a timeout row (create one directly) and `inbound_events` with a redacted token.
- Poll is audited and is 403 for `approver` (`approver` lacks `ops.payments.poll`).

```bash
bin/check && git add app config spec && git commit -m "Add operator search and payment detail with PSP calls, webhooks and poll now"
```

---

### Task 5: Redeliver a dead event with a reason (O-05)

`Ops::Api::EventsController#redeliver`:
- `requires_permission "ops.events.redeliver"`;
- `OutboundEvent.find`, then 422 unless dead;
- `redeliver!`, then `DeliverOutboundEventsJob.perform_later`;
- `audit!("event.redelivered", target: event, merchant_id: event.merchant_id, metadata: { "reason" => reason! })`.

Route: `resources :events, only: [] { post :redeliver, on: :member }`.

Spec:
- A reason is required (422 without).
- It is audited with the reason.
- `approver` gets 403.

```bash
bin/check && git add app config spec && git commit -m "Let operators redeliver dead events with an audited reason"
```

---

### Task 6: PSP circuit state (O-10)

**Files:**
- Modify: `app/lib/psp_circuit.rb` (public, read-only `snapshot`)
- Create: `app/controllers/ops/api/circuits_controller.rb`
- Test: `spec/lib/psp_circuit_spec.rb` (add), `spec/requests/ops/api/circuits_spec.rb`

`PspCircuit` has no public reader today. Add one that uses the same keys and never mutates:

```ruby
  class << self
    # Read-only view for the operator console. Never admits, never records.
    sig { params(psp: String).returns(T::Hash[String, T.untyped]) }
    def snapshot(psp)
      new(psp, store).snapshot
    end
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def snapshot
    open_until = @store.get(key("open_until"))&.to_f
    calls, fails = window
    state = if open_until.nil? then "closed"
            elsif now < open_until then "open"
            else "half_open"
            end
    { "psp" => @psp, "state" => state, "open_until" => open_until && Time.at(open_until).utc.iso8601,
      "window_calls" => calls, "window_failures" => fails }
  end
```

`snapshot` must be public; place it above `private`.

Spec: trip the circuit with the existing spec helpers, then check that `snapshot` says `open`, and that calling `snapshot` repeatedly does not change `window`.

Controller: `requires_permission "ops.circuits.read"` and `render json: { "data" => PspRouter::ADAPTERS.keys.map { PspCircuit.snapshot(_1) } }`. Route: `get "circuits", to: "circuits#index"`.

```bash
bin/check && git add app config spec && git commit -m "Expose read-only PSP circuit state to operators"
```

---

### Task 7: Reconciliation breaks and review (O-11)

**Files:**
- Create: `app/controllers/ops/api/reconciliation_breaks_controller.rb`
- Test: `spec/requests/ops/api/reconciliation_breaks_spec.rb`

`index` needs `ops.reconciliation.read` and returns:
- `settlement_lines` with status in (`unmatched`, `mismatch`), newest first, including `problem`, the review fields and the payment id;
- `ledger` with `Ledger.unbalanced_transfer_ids` and `Ledger.reservation_drift_refund_ids`. These are read-only lists; nothing marks them reviewed, because the ledger has no review column and fixing them is a proposal.

`review` needs `ops.reconciliation.review`:
- `line.update!(reviewed_at: Time.current, reviewed_by_id: current_user.id, review_note: reason!)`;
- 409 if already reviewed;
- audited.

Routes:

```ruby
      resources :reconciliation_breaks, only: :index do
        post :review, on: :member
      end
```

Spec:
- `ops` can review.
- `support` gets 403 on review.
- A second review gets 409.
- The review is audited.

```bash
bin/check && git add app config spec && git commit -m "Let operators review reconciliation and settlement breaks"
```

---

### Task 8: Proposals: create, list, withdraw

**Files:**
- Create: `app/controllers/ops/api/proposals_controller.rb`, `app/serializers/proposal_serializer.rb`
- Test: `spec/requests/ops/api/proposals_spec.rb`

```ruby
# app/controllers/ops/api/proposals_controller.rb (create, index, withdraw; approve/reject in Task 10)
      requires_permission "ops.payments.read", only: :index
      requires_permission "ops.proposals.create", only: %i[create withdraw]

      def index
        scope = OperatorProposal.includes(:payment, :proposed_by, :decided_by).order(created_at: :desc).limit(100)
        scope = scope.where(state: params[:state]) if params[:state].present?
        render json: { "data" => scope.map { |p| ProposalSerializer.call(p, viewer: current_user) } }
      end

      def create
        existing = OperatorProposal.find_by(client_token: params.require(:client_token))
        return render(json: ProposalSerializer.call(existing, viewer: current_user)) if existing&.proposed_by_id == current_user.id

        proposal = OperatorProposal.create!(
          kind: params.require(:kind), payment: Payment.find(params.require(:payment_id)),
          payload: params.require(:payload).permit!.to_h, reason_code: params.require(:reason_code),
          reason_text: params.require(:reason_text), case_reference: params.require(:case_reference),
          client_token: params[:client_token], proposed_by: current_user
        )
        audit!("proposal.created", target: proposal, merchant_id: proposal.payment.merchant_id,
                                   metadata: proposal.slice(:kind, :payload, :reason_code, :case_reference))
        Operator.active.where(role: "approver").find_each { |a| OperatorMailer.proposal_waiting(proposal, a).deliver_later } # authz-allow-role-check
        render json: ProposalSerializer.call(proposal, viewer: current_user), status: :created
      rescue ActiveRecord::RecordInvalid => e
        raise ApiError.validation(e.record.errors.to_hash.transform_keys(&:to_s))
      end

      def withdraw
        proposal = OperatorProposal.find(params[:id])
        raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused",
                           message: "Only the proposer can withdraw a pending proposal") unless
          proposal.proposed_by_id == current_user.id && proposal.state == "pending"

        proposal.update!(state: "withdrawn")
        audit!("proposal.withdrawn", target: proposal, merchant_id: proposal.payment.merchant_id)
        render json: ProposalSerializer.call(proposal, viewer: current_user)
      end
```

The approver notification selects operators by role. That is a mailing list, not an authorization check, hence the `authz-allow-role-check` comment. Better still, select by permission: `Operator.active.select { Permissions.granted?(:operator, _1.role, "ops.proposals.decide") }`. Use that and drop the comment.

`ProposalSerializer.call(proposal, viewer:)` returns id, kind, payment_id, merchant name, payload, reason fields, state, proposer email, decider email, the timestamps, error, `applied_transfer_id`, and `can: { approve:, reject:, withdraw: }`:
- `approve`/`reject` = viewer holds `ops.proposals.decide` && `proposal.approvable_by?(viewer)`;
- `withdraw` = proposer && pending.

Routes:

```ruby
      resources :proposals, only: %i[index create] do
        member do
          post :withdraw
          post :approve
          post :reject
        end
      end
```

Specs:
- `ops` creates a transition proposal for an `unknown` payment; approvers are emailed; the proposal is audited.
- A retried create with the same `client_token` returns the same proposal.
- `support` gets 403.
- Only the proposer withdraws.

Spec the `can` flags after Task 10 (they call `approvable_by?`).

```bash
bin/check && git add app config spec && git commit -m "Let ops operators propose manual transitions and ledger corrections"
```

---

### Task 9: Applying an approved proposal

**Files:**
- Create: `app/services/apply_proposal.rb`
- Test: `spec/services/apply_proposal_spec.rb`

```ruby
# app/services/apply_proposal.rb
# typed: true
# frozen_string_literal: true

# Runs inside the approval transaction, after the proposal row is locked.
# Never forces: if the payment has moved since the proposal was made, the
# proposal fails and nothing changes (design §4).
module ApplyProposal
  class Stale < StandardError; end

  def self.call(proposal, approver:)
    case proposal.kind
    when "payment_transition" then transition(proposal, approver)
    when "ledger_correction" then correction(proposal, approver)
    end
  end

  def self.transition(proposal, approver)
    payment = proposal.payment
    payment.with_lock do
      allowed = OperatorProposal::ALLOWED_TRANSITIONS.fetch(payment.state, [])
      raise Stale, "payment is #{payment.state} now; propose again if still needed" unless allowed.include?(proposal.payload["to_state"])

      t = payment.transition!(proposal.payload.fetch("to_state"), sort_key: Time.current, source: "operator",
                              metadata: metadata(proposal, approver))
      raise Stale, "transition was not applied (a newer PSP event exists)" unless t.applied?
    end
  end

  def self.correction(proposal, approver)
    proposal.update!(applied_transfer_id: Ledger.record!(
      merchant: proposal.payment.merchant, currency: proposal.payload.fetch("currency"),
      legs: proposal.legs, payment: proposal.payment
    ))
  end

  def self.metadata(proposal, approver)
    { "proposal_id" => proposal.id, "proposed_by" => proposal.proposed_by.email, "approved_by" => approver.email,
      "reason_code" => proposal.reason_code, "reason" => proposal.reason_text, "case_reference" => proposal.case_reference }
  end
end
```

Check whether `Payment#transition!` to `authorized` or `failed` emits the merchant's outbound event itself (grep `OutboundEvent.emit!` in `app/models/payment.rb` and the services). If only callers emit, emit the same event type the sweeper would (`payment.authorized` / `payment.failed`) here, so the merchant hears about an operator resolution exactly as about any other.

Specs:
- An `unknown → failed` proposal applies, with a transition of source `operator` carrying `proposal_id` and both emails.
- If the payment became `authorized` first, the proposal raises `Stale`.
- A ledger correction posts one balanced transfer, `Ledger.unbalanced_transfer_ids` stays empty, and `applied_transfer_id` is set.

```bash
bin/check && git add app spec && git commit -m "Apply approved proposals through transition! and Ledger, never by force"
```

---

### Task 10: Approve and reject, with the maker-checker guard

**Files:**
- Modify: `app/models/operator_proposal.rb` (`approvable_by?`), `app/controllers/ops/api/proposals_controller.rb`
- Test: `spec/models/operator_proposal_spec.rb` (add), `spec/requests/ops/api/proposals_spec.rb` (add)

**Step 1: Specs first**

```ruby
  describe "#approvable_by?" do
    let(:proposal) { create(:operator_proposal, payment:, proposed_by: maker) }

    it "is false for the proposer, whatever their role" do
      maker.update!(role: "approver")
      expect(proposal.approvable_by?(maker)).to be(false)
    end

    it "is true for another active approver while pending" do
      expect(proposal.approvable_by?(checker)).to be(true)
    end

    it "is false once decided, withdrawn or failed" do
      proposal.update!(state: "withdrawn")
      expect(proposal.approvable_by?(checker)).to be(false)
    end

    it "is false for a disabled operator" do
      checker.update!(disabled_at: Time.current)
      expect(proposal.approvable_by?(checker)).to be(false)
    end
  end
```

**Step 2: USER WRITES `OperatorProposal#approvable_by?(operator)`**

Hand the user the scaffold already in the model:

```ruby
  # The maker-checker guard (design §3 layer 4, DECISIONS #23). Called
  # twice: to compute the `can.approve` flag, and again under the row lock
  # before applying. The database CHECK is the backstop for self-approval,
  # not the only defence.
  def approvable_by?(operator)
    # TODO(user): 5-10 lines. Decide:
    # - the obvious: pending only; not the proposer; the operator active.
    # - does it check the PERMISSION (ops.proposals.decide) here, or leave
    #   that to requires_permission in the controller? Checking here too makes
    #   the flag right for any caller; leaving it out keeps one source of truth.
    # - is there a staleness rule, e.g. a proposal older than 24h must be
    #   re-proposed so nobody approves yesterday's picture of a payment?
    # - should an operator who was the approver on an EARLIER proposal for the
    #   same payment be barred, so one pair cannot ping-pong changes?
    # Trade-off: every extra rule lowers the chance of a bad change and raises
    # the chance a real fix waits at 3am because nobody eligible is awake.
    raise NotImplementedError
  end
```

Continue once the model specs pass.

**Step 3: Controller**

```ruby
      requires_permission "ops.proposals.decide", only: %i[approve reject]

      def approve = decide(approve: true)
      def reject = decide(approve: false)

      private

      def decide(approve:)
        note = params[:note].to_s.strip.presence
        raise ApiError.validation("note" => ["is required to reject"]) if !approve && note.nil?

        proposal = OperatorProposal.find(params[:id])
        OperatorProposal.transaction do
          proposal.lock!
          unless proposal.approvable_by?(current_user)
            raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused",
                               message: "This proposal is not yours to decide (already decided, withdrawn, or your own)")
          end

          proposal.update!(decided_by: current_user, decided_at: Time.current, decision_note: note,
                           state: approve ? "applied" : "rejected")
          if approve
            begin
              OperatorProposal.transaction(requires_new: true) { ApplyProposal.call(proposal, approver: current_user) }
              proposal.update!(applied_at: Time.current)
            rescue ApplyProposal::Stale, PaymentStateMachine::IllegalTransition, Ledger::Unbalanced => e
              proposal.update!(state: "failed", error: e.message)
            end
          end
        end
        audit!("proposal.#{proposal.state}", target: proposal, merchant_id: proposal.payment.merchant_id,
                                             metadata: { "note" => note, "error" => proposal.error }.compact)
        render json: ProposalSerializer.call(proposal.reload, viewer: current_user)
      end
```

The inner savepoint means a failed apply rolls back only the apply; the decision and the `failed` state still commit. The audit row is written after the transaction commits, so it records what actually happened.

**Step 4: Request specs**
- **Self-approval refused:** an operator who holds both roles in a test setup (use `update_columns(role:)` to force it) gets 409 on their own proposal.
- **Two approvers race:** use two threads with `:concurrency` and check that exactly one decision lands and the other gets 409. Follow `spec/services/idempotency_guard_spec.rb`'s concurrency pattern.
- **Stale:** approving a proposal whose payment already moved gives state `failed` with an error, and the payment is unchanged.
- **Reject** needs a note.
- `ops` gets 403 on approve.
- `admin` gets 403 on approve; this is the design's "admin cannot approve money".

```bash
bin/check && git add app spec && git commit -m "Approve or reject proposals under a row lock with the maker-checker guard"
```

---

### Task 11: View as merchant (O-12)

**Files:**
- Create: `app/controllers/ops/api/impersonations_controller.rb`, `app/controllers/concerns/impersonation_context.rb`
- Modify: `app/controllers/dashboard/api/base_controller.rb`, `config/routes.rb`
- Test: `spec/requests/ops/api/impersonation_spec.rb`

**Step 1: Starting and stopping**

`ImpersonationsController`:
- `create`: `requires_permission "ops.impersonation.start"`, step-up (the permission is sensitive), `merchant = Merchant.where(livemode: true).find(params.require(:merchant_id))`, and `current_session.start_impersonation!(merchant_id:, case_ref: params.require(:case_reference))`. Audit `impersonation.started` with `on_behalf_of_merchant_id`. Also write an `audit_events` row with `merchant_id: merchant.id`, so the merchant's own security history shows "PayHub support viewed your account".
- `destroy`: `allow_unauthorized` (ending is always allowed), `stop_impersonation!`, audit.

**Step 2: Reusing the merchant read endpoints**

Routes, inside `namespace :ops … namespace :api`:

```ruby
      resources :impersonations, only: %i[create]
      delete "impersonations/current", to: "impersonations#destroy"

      # Read-only merchant view (design §4): the Phase 1 controllers, GET only.
      scope "as/:as_merchant_id", module: "/dashboard/api", as: "as_merchant", defaults: { impersonation: "1" } do
        get "home", to: "home#show"
        resources :payments, only: %i[index show]
        get "balance", to: "balances#show"
        get "settlements", to: "settlements#index"
        resources :api_keys, only: :index
        resource :webhook_endpoint, only: :show
        resources :events, only: %i[index show]
        resources :members, only: :index
        get "security_history", to: "security_history#index"
      end
```

`Dashboard::Api::BaseController#require_session!` gains a branch. When `params[:impersonation] == "1"`:
- read the **ops** cookie (sent because the path is under `/ops`) and load the operator session;
- require `impersonating?` and `impersonating_merchant_id == params[:as_merchant_id]`, otherwise 403 `impersonation_expired`;
- set `@impersonator = operator`, `@current_user = nil`, and `@impersonated_merchant = Merchant.find(...)`;
- `live_merchant` returns `@impersonated_merchant`;
- `current_merchant` is always the live merchant; impersonation shows live data only.

Put the branch in `app/controllers/concerns/impersonation_context.rb` so the base controller stays readable. It defines:

```ruby
  # Read-only: any merchant permission ending in .read, nothing else, whatever
  # the operator's role (design §3 layer 5).
  def permission_granted?(permission)
    return super unless impersonating_request?

    permission.end_with?(".read") && Permissions.known?(permission)
  end

  def authorization_role = impersonating_request? ? "impersonation" : super
```

`authorize!` checks `authorization_role.nil?` first, so return a non-nil marker here. `permission_granted?` never consults the role in this branch.

`audit!` in the base controller, while impersonating, records `actor: @impersonator`, `actor_label: "#{operator.email} (PayHub support)"`, and `on_behalf_of_merchant_id: merchant.id`.

Guard writes in two ways:
- the routes above are GET only;
- `permission_granted?` refuses every non-`.read` permission, so a POST route added under `as/` later is refused with 403. Give that refusal the code `impersonation_read_only`: override `record_denial`'s raise path, or rescue in the concern and re-raise `ApiError.new(… http_status: 403, code: "impersonation_read_only" …)`.

**Step 3: Specs**
- `support` starts an impersonation with a case reference (step-up), reads `/ops/api/as/<id>/payments`, and sees that merchant's live payments.
- Reading another merchant's id under the same impersonation gives 403.
- After 31 minutes: 403 `impersonation_expired`.
- A merchant cookie alone cannot use `/ops/api/as/...` (401).
- `approver` gets 403 on start.
- The merchant's security history (Phase 1 endpoint) shows the impersonation start.
- Route inventory: no non-GET route under `/ops/api/as/`. Add this assertion to `spec/routing/authorization_inventory_spec.rb`.

```bash
bin/check && git add app config spec && git commit -m "Let support view a merchant's dashboard read-only for 30 minutes with a case reference"
```

---

### Task 12: Operators management and access review (O-13, O-14)

`Ops::Api::OperatorsController`:
- `index` needs `ops.operators.manage`.
- `create` is Task 2's invite (move it here if simpler).
- `update` changes the role. Refuse self (409) and audit `operator.role_changed` with from/to.
- `destroy` disables the operator and revokes their sessions; refuse self.
- `access_review` (CSV) needs `ops.access_review.export`, with columns `email,role,permissions,last_sign_in_at,created_at,disabled_at`. `last_sign_in_at` is the newest `sessions.created_at`: preload it with one grouped query, not N+1.

Also add a **merchant** access review to the same CSV (`area,merchant,email,role,…`), because PCI 7.2.4 covers everyone with access to cardholder-data systems, not only staff.

Specs:
- `ops` gets 403.
- An admin cannot change their own role.
- The CSV lists both areas.
- A disabled operator's session gets 401 on the next request.

Routes:

```ruby
      resources :operators, only: %i[index create update destroy]
      get "access_review", to: "operators#access_review"
```

```bash
bin/check && git add app config spec && git commit -m "Add operator management and a both-areas access review export"
```

---

### Task 13: Operator audit stream (O-15)

`Ops::Api::AuditEventsController#index`: `requires_permission "ops.audit.read"`, with cursor pagination over `AuditEvent` and filters `actor_type`, `action` prefix, `merchant_id`, `on_behalf_of_merchant_id` and date range. Every audit row is visible, both merchant and operator.

Check that `EXPLAIN` uses the `(action, created_at)` or `(merchant_id, created_at)` indexes from Phase 0 for each filter. Without a filter it is a scan of the newest rows by `created_at`; add an index on `(created_at DESC, id DESC)` if the plan shows a sort.

Spec: filters work, and `support` can read (all operator roles hold `ops.audit.read`).

```bash
bin/check && git add app config spec db && git commit -m "Add the operator audit stream"
```

---

### Task 14: Close the Phase 0 review leftovers

1. **No `psp_calls` row for unexpected Faraday errors.** In both adapters' `send_request`, add a final `rescue Faraday::Error => e` that records `outcome: "unreachable"` (with `http_status: nil`) and re-raises unchanged. Spec with WebMock `to_raise(Faraday::SSLError)`.
2. **`CancelPayment` rolls back its own `psp_calls` rows.** Move the PSP call out of the `with_lock` block: read the state under the lock, release it, call the PSP, then re-lock and re-check before transitioning. That is DECISIONS #13's rule ("locks are released before HTTP calls"), which `CancelPayment` breaks.

   This changes money-path behaviour. Write the concurrency spec first: a cancel racing a capture on an `authorized` payment must end with exactly one of them applied. Run `spec/simulation` and `spec/properties` before and after. If the change grows past about 40 lines, stop and ask the user whether to split it into its own PR.

```bash
bin/check && git add app spec && git commit -m "Record unexpected PSP transport errors and stop CancelPayment holding a lock across HTTP"
```

---

### Task 15: Operator pages

**Files:**
- Create: `app/frontend/ops/api.ts`, `router.ts`, `useMe.ts`, `layouts/OpsLayout.vue`
- Create pages under `app/frontend/ops/pages/`: `SignIn.vue`, `AcceptInvitation.vue`, `EnrolOtp.vue`, `Queue.vue`, `Search.vue`, `PaymentDetail.vue`, `Proposals.vue`, `ProposalDetail.vue`, `Circuits.vue`, `Reconciliation.vue`, `Operators.vue`, `Audit.vue`, `ImpersonationView.vue`
- Modify: `app/frontend/entrypoints/ops.ts`
- Move to `app/frontend/shared/`: every component Phase 1 built that ops also needs (`StepUpDialog`, `ConfirmDialog`, `ErrorBanner`, `StatusBadge`, `Timeline`, and the sign-in/enrol pages parameterised by client). Keep `merchant/` importing from `shared/`. Do the move as its own commit first, with Phase 1's Vitest tests as the regression suite.

| Page | Must |
|---|---|
| `Queue.vue` | Four sections; each unknown payment links to its detail; "stuck for" is relative time; auto-refresh every 30s via `useLiveQuery` (pause when hidden). |
| `Search.vue` | One box. Tells the operator what it matches (id, `ph_` reference, merchant name prefix). |
| `PaymentDetail.vue` | Merchant header with a **Live/Test** badge; timeline; a **PSP calls** table where a timeout row shows "no response (timed out after N ms)"; an **inbound webhooks** table with an invalid-signature badge; the payment's proposals. "Poll PSP now" only with `ops.payments.poll`; 503 shows "PSP circuit open, try after …". "Propose resolution" only with `ops.proposals.create` and state `unknown`. |
| Proposal dialog | Target state (authorized / failed), reason code, free text, case reference; `client_token` from `useIdempotencyKey`. Shows the latest PSP call and webhook beside the form, so the proposer cites evidence. |
| `ProposalDetail.vue` | Everything the approver needs **on one screen**: payload, proposer, reason, case ref, the payment's current state and its last PSP call. Approve and Reject only when `can.approve` / `can.reject`; reject needs a note. After approve, show `applied` or `failed` with the error. |
| `Circuits.vue` | One card per PSP: state, open until, window calls/failures. Refresh every 10s. |
| `Reconciliation.vue` | Settlement breaks with a review action (note required); ledger anomalies listed with "propose correction" links. |
| `Operators.vue` | List, invite, role change, disable; "Export access review" link. |
| `Audit.vue` | Filterable stream. |
| Impersonation | Start from a merchant (search result or payment header) with a case reference. While active, `OpsLayout` shows a red, fixed **"Viewing <merchant> as PayHub support, read-only, ends at HH:MM"** banner on every screen, plus an "End" button. `ImpersonationView.vue` reuses the merchant pages' read components against `createClient(\`/ops/api/as/${id}\`)`. It may import merchant page components if they take the client as a prop. Refactor them to do that. |

Vitest:
- `OpsLayout` shows the impersonation banner when `me.impersonating` is set.
- `ProposalDetail` hides Approve when `can.approve` is false.

```bash
bin/check && git add app/frontend && git commit -m "Build the operator console pages"
```

---

### Task 16: Playwright flow 2: operator proposes, a second operator approves

Extend `lib/tasks/e2e.rake` with `e2e:seed_ops`:
- two operators, `ops@e2e.test` (role `ops`, secret `JBSWY3DPEHPK3PXP`) and `approver@e2e.test` (role `approver`, secret `KRSXG5CTMVRXEZLU`);
- a payment in `unknown` with one `psp_calls` timeout row.

```ts
// e2e/operator.spec.ts
// 1. ops@ signs in (2FA), opens the queue, opens the unknown payment, proposes "failed"
//    with reason psp_confirmed_outcome and case OPS-42, and sees the proposal pending.
// 2. In a NEW browser context (separate cookies), approver@ signs in, opens Proposals,
//    opens OPS-42, steps up if asked, approves, and sees "applied".
// 3. Back in the ops@ context, the payment detail now shows state "failed" and a
//    transition with source "operator".
// 4. Negative: ops@ has no Approve button on their own proposal.
```

Write it in full following `e2e/merchant.spec.ts`: `new TOTP({ secret })`, wait for the next 30-second step before a second code from the same user, and `browser.newContext()` for the approver. Add `npm run e2e` coverage to the existing CI job (Playwright runs every spec in `e2e/`).

```bash
bin/check && npm run e2e && git add e2e lib/tasks/e2e.rake && git commit -m "Add the propose-and-approve end-to-end test"
```

---

### Task 17: Decisions, runbook, verification

1. **DECISIONS #26: operator writes are made safe by state, not idempotency keys.**
   - **Decision:** row locks, state preconditions and a `client_token` on proposals.
   - **Rejected:** a merchant-less IdempotencyGuard.
   - **Reason:** every operator write already has a natural precondition, and the guard's key space is per merchant.
2. **DECISIONS #23:** amend it to describe what was built. Mention the savepoint that lets a failed apply still record the decision.
3. **RUNBOOK §5:** replace "If you must move the payment tonight … a transition with `source: "operator"` … from a console" with the proposal flow:
   - open the payment in `/ops`;
   - read the PSP calls and webhooks;
   - propose;
   - page an approver.

   Keep the console command only as a documented break-glass, requiring two named people in the incident ticket.
4. **README:** operator console section, `operators:invite`, the four roles.
5. Verify:
   - `bin/check`;
   - `npm run e2e`;
   - compose stack + `chaos:run[30]`;
   - by hand: invite an admin via `bin/rails "operators:invite[you@example.com,admin]"`, then invite an ops operator and an approver from the UI, and run the propose/approve flow on a payment the chaos run left in `unknown` (or force one with `X-Sim-Force: timeout` via curl against the simulator);
   - then @superpowers:verification-before-completion and @superpowers:requesting-code-review.

```bash
bin/check && git add DECISIONS.md RUNBOOK.md README.md && git commit -m "Record decision #26 and replace the console runbook step with maker-checker"
```
