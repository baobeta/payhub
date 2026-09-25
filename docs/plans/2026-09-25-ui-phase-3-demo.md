# PayHub UI Phase 3: Public Demo Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A visitor, with no login, can use `/demo` to:
- create a test payment whose outcome they pick (success, decline, timeout then webhook, timeout needing an operator, wallet redirect);
- watch it move through a live state-machine diagram;
- approve a wallet redirect as the "customer";
- run a small chaos run and watch the invariants hold;
- see every ledger transfer net to zero;
- reset the demo.

All of this touches only the **test twin of the seeded demo merchant**.

**Architecture:**
- **Magic tokens.** Both PSP simulators gain deterministic behaviour for `tok_demo_*` tokens by mapping each token onto the forced-behaviour mechanism they already have (`X-Sim-Force`). Every other token keeps its random chaos.
- **Controllers.** `Demo::Api::*` controllers are public (`allow_unauthorized`). They are CSRF-protected, throttled per IP, and scoped to one merchant id resolved on the server.
- **Reset.** The ledger is append-only and payments cannot be deleted, so "reset" starts a new **demo epoch**: the demo shows only rows created since the current epoch began.
- **Chaos run.** Moves out of the rake file into `app/lib/chaos_run.rb`, so a Sidekiq job can drive a small run and store its result.
- **State diagram.** Generated from `PaymentStateMachine`, the same way the permission union is generated, so the diagram cannot drift from the code.

**Tech Stack:** as Phases 1 and 2; Sinatra simulators (`simulators/*/app.rb`, their own RSpec).

**Design sources:** [UI design](2026-09-25-ui-design.md) §4 Demo table and abuse limits; [use cases](2026-09-25-ui-use-cases.md) D-01 to D-06; DECISIONS #10 (state diagram), #5 (ledger), README "Chaos".

**Prerequisite:** Phases 1 and 2 merged. This plan reuses `PaymentTimeline`, `useLiveQuery`, `createClient`, `pollIntervalFor`, shared components, and the operator proposal flow (the "needs operator" scenario ends in the ops queue).

---

## Conventions

Same as Phase 1. Simulator specs run inside each simulator: `cd simulators/nordpay && bundle exec rspec`. The Docker images rebuild with `docker compose build nordpay kiripay`.

---

### Task 0: Branch

```bash
git checkout master && git pull && git checkout -b feature/ui-phase-3-demo
```

---

### Task 1: Magic tokens in the Nordpay simulator

**Files:**
- Modify: `simulators/nordpay/app.rb`
- Test: `simulators/nordpay/spec/app_spec.rb`

The simulator already rolls each behaviour through `inject?(behaviour, forced_header)`, and `X-Sim-Force` overrides the dice. A magic token becomes a **default forced list** for that charge, remembered on the charge so later reads (`GET /charges/:ref`) behave the same.

| Token | Forced behaviours | What PayHub sees |
|---|---|---|
| `tok_demo_success` | `none` | authorized (or captured), webhook on time |
| `tok_demo_decline` | `decline` | failed with `insufficient_funds` |
| `tok_demo_timeout_webhook` | `timeout` | `unknown`, then the webhook (sent before the hang) resolves it to authorized |
| `tok_demo_timeout_needs_operator` | `timeout`, `webhook_never`, `read_timeout` | `unknown`, and every poll times out too, so it stays there until an operator acts |

`none` is not a real behaviour. Forcing it makes `forced.any?` true, which switches the random dice off: a deterministic success.

**Step 1: Failing specs**

Read the existing spec's setup first (it sets rates to 0 and uses `Rack::Test`). Then add:

```ruby
  describe "magic demo tokens" do
    def charge(token, reference: "ph_#{SecureRandom.hex(12)}")
      header "Authorization", "Bearer np_test_key"
      header "X-Request-Id", reference
      post "/charges", { amount_minor: 2500, currency: "EUR", payment_method_token: token }.to_json
      reference
    end

    before { app.settings.failure.merge!("decline_rate" => 1.0) } # random chaos ON, to prove tokens override it

    it "tok_demo_success always authorizes, whatever the dice say" do
      charge("tok_demo_success")
      expect(JSON.parse(last_response.body)["status"]).to eq("authorized")
    end

    it "tok_demo_decline always declines" do
      app.settings.failure.merge!("decline_rate" => 0.0)
      charge("tok_demo_decline")
      expect(JSON.parse(last_response.body)["status"]).to eq("declined")
    end

    it "tok_demo_timeout_needs_operator makes later reads hang too" do
      app.settings.failure.merge!("timeout_seconds" => 0.01)
      ref = charge("tok_demo_timeout_needs_operator")
      started = Time.now
      get "/charges/#{ref}"
      expect(Time.now - started).to be >= 0.01
      expect(app.settings.store.find(ref).magic).to eq("tok_demo_timeout_needs_operator")
    end
  end
```

Run: `cd simulators/nordpay && bundle exec rspec`
Expected: the new examples FAIL.

**Step 2: Implement**

In `simulators/nordpay/app.rb`:

```ruby
    # Deterministic outcomes for the public demo. Each token is a default
    # X-Sim-Force list, remembered on the charge so reads behave the same.
    MAGIC_TOKENS = {
      "tok_demo_success" => %w[none],
      "tok_demo_decline" => %w[decline],
      "tok_demo_timeout_webhook" => %w[timeout],
      "tok_demo_timeout_needs_operator" => %w[timeout webhook_never read_timeout]
    }.freeze
```

- Add `attr_accessor :magic` to the charge struct (or its `Struct.new` members), and set `charge.magic = body["payment_method_token"] if MAGIC_TOKENS.key?(…)` inside the `if charge.status.nil?` block of `POST /charges`.
- Change `inject?` so an explicit `X-Sim-Force` header still wins, then the charge's magic list, then the dice:

```ruby
      def inject?(behaviour, forced_header = request.env["HTTP_X_SIM_FORCE"].to_s, charge: @current_charge)
        forced = forced_header.split(",").map(&:strip)
        forced = MAGIC_TOKENS.fetch(charge&.magic.to_s, []) if forced.empty?
        return true if forced.include?(behaviour)
        return false if forced.any?

        rate = config.fetch("#{behaviour}_rate", 0).to_f
        rate.positive? && rand < rate
      end
```

- Set `@current_charge = charge` in each route once the charge is known: `POST /charges` after `find_or_create`, and `GET /charges/:reference`, capture, void and refund after `store.find`.
- `emit!` already threads a forced header through. Check that its `webhook_never` / `webhook_duplicate` / … rolls call `inject?` with the charge in scope.
- In `GET /charges/:reference`, before responding: `sleep(config.fetch("timeout_seconds", 5).to_f) if inject?("read_timeout")`. It is a new behaviour with no random rate, so only a magic token or a forced header triggers it.

Run the simulator spec. Expected: PASS, including the existing examples.

**Step 3: Commit**

```bash
(cd simulators/nordpay && bundle exec rspec) && git add simulators/nordpay && \
  git commit -m "Nordpay simulator: deterministic outcomes for tok_demo_* tokens"
```

---

### Task 2: Magic tokens in the Kiripay simulator

Same pattern in `simulators/kiripay/app.rb`. The token arrives as `wallet_token` in `POST /charges`, and Kiripay's charges are looked up by `merchant_reference`.

| Token | Forced | Effect |
|---|---|---|
| `tok_demo_wallet` | `none` | always `pending_redirect`, no random duplicates or failures; the visitor approves it (Task 6) |

Spec: with every random rate at 1.0, `tok_demo_wallet` still produces exactly one `pending_redirect` charge. `POST /_sim/charges/:id/approve` then settles it.

```bash
(cd simulators/kiripay && bundle exec rspec) && git add simulators/kiripay && \
  git commit -m "Kiripay simulator: a deterministic wallet redirect for the demo"
```

---

### Task 3: Demo merchant and epochs

**Files:**
- Create: `db/migrate/20260928000001_create_demo_epochs_and_chaos_runs.rb`
- Create: `app/models/demo_epoch.rb`, `app/models/demo_chaos_run.rb`, `app/lib/demo_merchant.rb`
- Test: `spec/lib/demo_merchant_spec.rb`, `spec/models/demo_chaos_run_spec.rb`

**Step 1: Migration**

```ruby
class CreateDemoEpochsAndChaosRuns < ActiveRecord::Migration[8.1]
  # "Reset" cannot delete: payments and ledger entries are append-only
  # (DECISIONS #5). A reset starts a new epoch; the demo shows rows created
  # since the current one began.
  def up
    create_table :demo_epochs, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.datetime :started_at, null: false
      t.string :started_by_ip
    end
    add_index :demo_epochs, :started_at

    create_table :demo_chaos_runs, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :state, null: false, default: "queued"
      t.integer :payments, null: false
      t.jsonb :result
      t.string :error
      t.string :started_by_ip
      t.datetime :finished_at
      t.timestamps
    end
    add_check_constraint :demo_chaos_runs, "state IN ('queued', 'running', 'passed', 'failed', 'errored')", name: "chk_demo_chaos_runs_state"
    add_check_constraint :demo_chaos_runs, "payments BETWEEN 1 AND 20", name: "chk_demo_chaos_runs_size"
    # One chaos run at a time, system-wide (design §4 abuse limits).
    add_index :demo_chaos_runs, :state, unique: true, where: "state IN ('queued', 'running')", name: "idx_demo_chaos_runs_one_active"
  end

  def down
    drop_table :demo_chaos_runs
    drop_table :demo_epochs
  end
end
```

**Step 2: DemoMerchant**

```ruby
# app/lib/demo_merchant.rb
# typed: true
# frozen_string_literal: true

# The one merchant the public demo may touch: the TEST twin of the seeded
# "Demo Merchant". Resolved on the server; never taken from a request.
module DemoMerchant
  NAME = "Demo Merchant"

  def self.live = Merchant.find_by!(name: NAME, livemode: true)
  def self.twin = live.test_twin!

  def self.epoch_started_at = DemoEpoch.order(:started_at).last&.started_at || Time.zone.at(0)

  # Payments the demo shows: the twin's, created since the current epoch.
  def self.payments = twin.payments.where(created_at: epoch_started_at..)
end
```

`db/seeds.rb` already creates the Demo Merchant (Phase 0). The demo raises `ActiveRecord::RecordNotFound` if it is missing; `Demo::Api::BaseController` turns that into 503 `demo_not_seeded`.

Specs:
- `DemoMerchant.twin` is the twin, never the live merchant.
- `payments` excludes rows from before the latest epoch.
- `DemoChaosRun` refuses a second active run (`RecordNotUnique`) and a run of 21 payments (CHECK).

```bash
bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate && bin/rails db:schema:dump && bin/tapioca dsl
bin/check && git add db app spec sorbet/rbi && git commit -m "Add demo epochs and chaos runs, scoped to the demo merchant's test twin"
```

---

### Task 4: State machine export for the diagram

**Files:**
- Create: `app/lib/state_machine_export.rb`, generated `app/frontend/shared/stateMachine.ts`
- Modify: `lib/tasks/permissions.rake` → rename the task to `exports:all` (keep `permissions:export` as an alias), `bin/check`
- Test: `spec/lib/state_machine_export_spec.rb`

```ruby
# app/lib/state_machine_export.rb
# typed: true
# frozen_string_literal: true

# The demo's diagram is drawn from this file, generated from
# PaymentStateMachine, so it can never show an edge the code refuses.
module StateMachineExport
  def self.typescript
    edges = PaymentStateMachine::TRANSITIONS.flat_map { |from, tos| tos.map { |to| [from.to_s, to] } }
    <<~TS
      // Generated by `bin/rails exports:all` from app/lib/payment_state_machine.rb. Do not edit.
      export const STATES = #{JSON.generate(PaymentStateMachine::STATES)} as const;
      export const TERMINAL = #{JSON.generate(PaymentStateMachine::TERMINAL)} as const;
      export const EDGES: ReadonlyArray<readonly [string, string]> = #{JSON.generate(edges)};
    TS
  end
end
```

Spec:
- The output includes `["unknown","failed"]`.
- It does not include `["unknown","canceled"]`, the edge DECISIONS #10 deliberately omits.

Extend the Phase 0 staleness gate in `bin/check` to also `git diff --exit-code -- app/frontend/shared/stateMachine.ts`.

```bash
bin/check && git add app/lib/state_machine_export.rb app/frontend/shared/stateMachine.ts lib/tasks bin/check spec && \
  git commit -m "Generate the payment state machine for the demo diagram; fail CI when stale"
```

---

### Task 5: Demo API: payments with scenarios

**Files:**
- Create: `app/controllers/demo/api/base_controller.rb`, `app/controllers/demo/api/payments_controller.rb`
- Modify: `config/routes.rb`
- Test: `spec/requests/demo/api/payments_spec.rb`

```ruby
# app/controllers/demo/api/base_controller.rb
# typed: true
# frozen_string_literal: true

module Demo
  module Api
    # Public by design: no login, test data only, one merchant. Every action
    # is public, so the declaration covers the whole controller.
    class BaseController < Web::BaseController
      wrap_parameters false
      allow_unauthorized

      rescue_from ActiveRecord::RecordNotFound do
        render_api_error(ApiError.not_found("resource"))
      end
      rescue_from ActionController::ParameterMissing do |e|
        render_api_error(ApiError.invalid_request("Missing parameter: #{e.param}", param: e.param.to_s))
      end

      private

      def authorization_area = :merchant
      def merchant = @merchant ||= DemoMerchant.twin
    end
  end
end
```

`allow_unauthorized` with no `only:` must mark every action as declared. Check `authorization_declared_for?` returns true for any action when `only` and `except` are nil (the Phase 0 `rule_applies?` does); the route inventory spec proves it.

```ruby
# app/controllers/demo/api/payments_controller.rb
# typed: true
# frozen_string_literal: true

module Demo
  module Api
    class PaymentsController < BaseController
      SCENARIOS = {
        "success" => { token: "tok_demo_success", currency: "EUR", amount_minor: 2500 },
        "decline" => { token: "tok_demo_decline", currency: "EUR", amount_minor: 2500 },
        "timeout_then_webhook" => { token: "tok_demo_timeout_webhook", currency: "EUR", amount_minor: 2500 },
        "timeout_needs_operator" => { token: "tok_demo_timeout_needs_operator", currency: "EUR", amount_minor: 2500 },
        "wallet_redirect" => { token: "tok_demo_wallet", currency: "VND", amount_minor: 500_000 }
      }.freeze

      def create
        scenario = SCENARIOS.fetch(params.require(:scenario).to_s) do
          raise ApiError.validation("scenario" => ["must be one of #{SCENARIOS.keys.join(', ')}"])
        end
        payment = CreatePayment.call(merchant, CreatePayment::Params.new(
          amount_minor: scenario[:amount_minor], currency: scenario[:currency], payment_method_token: scenario[:token],
          capture: params[:capture] == true, metadata: { "demo_scenario" => params[:scenario].to_s }
        ))
        render json: detail(payment), status: :accepted
      end

      def show = render(json: detail(DemoMerchant.payments.find(params[:id])))

      private

      def detail(payment)
        PaymentSerializer.call(payment).merge("timeline" => PaymentTimeline.call(payment))
      end
    end
  end
end
```

Check `CreatePayment::Params` field names against `app/services/create_payment.rb` (Phase 0 used `amount_minor`, `currency`, `payment_method_token`, `capture`, `metadata`).

Routes:

```ruby
  namespace :demo do
    namespace :api, defaults: { format: :json } do
      resources :payments, only: %i[create show] do
        post :approve_wallet, on: :member
      end
      resources :chaos_runs, only: %i[create show]
      get "ledger_summary", to: "ledger#show"
      post "reset", to: "resets#create"
    end
  end
```

Specs:
- Each scenario creates a payment on the **twin**; `DemoMerchant.live.payments` is unchanged.
- An unknown scenario gives 422.
- Showing a payment of another merchant gives 404.
- Showing a payment from before the current epoch gives 404.
- The metadata records the scenario.

```bash
bin/check && git add app config spec && git commit -m "Add public demo payments driven by scenario"
```

---

### Task 6: Wallet approval, the "customer" pressing approve (D-03)

`PaymentsController#approve_wallet`:
- find the payment in `DemoMerchant.payments`;
- 409 unless `state == "requires_action"` and `psp_name == "kiripay"`;
- read the Kiripay charge id from the latest transition's `metadata["psp_charge_id"]`. Check which key the Kiripay adapter records by grepping `psp_charge_id` in `app/services/apply_psp_result.rb`;
- `POST #{ENV.fetch('KIRIPAY_URL', 'http://localhost:4002')}/_sim/charges/#{id}/approve` via Faraday with a 3s timeout;
- the simulator then sends signed webhooks and the payment becomes `captured`;
- return the payment detail.

Spec: stub the simulator with WebMock and check that the approve call is made with the charge id. Also check the 409 for a card payment.

This endpoint exists only because the simulator does. Guard it with `raise ApiError.not_found("resource") if Rails.env.production?`, so it cannot talk to a real PSP.

```bash
bin/check && git add app spec && git commit -m "Let demo visitors approve a wallet redirect as the customer"
```

---

### Task 7: Extract ChaosRun and run it from the demo (D-04)

**Files:**
- Create: `app/lib/chaos_run.rb` (moved from `lib/tasks/chaos.rake`), `app/jobs/demo_chaos_run_job.rb`, `app/controllers/demo/api/chaos_runs_controller.rb`
- Modify: `lib/tasks/chaos.rake` (now 10 lines: build and call)
- Test: `spec/jobs/demo_chaos_run_job_spec.rb`, `spec/requests/demo/api/chaos_runs_spec.rb`

**Step 1: Move without changing behaviour**

Move `class ChaosRun` into `app/lib/chaos_run.rb` with three changes:
1. **Constructor:** `initialize(payments:, merchant: nil, api_key: nil, out: $stdout)`. With no merchant, it creates one as today (the rake path). Given one, it uses it and the given raw key.
2. **Output:** `say` writes to `out`; `check` also appends `{ label:, passed: }` to `@checks`.
3. **Return value:** `call` returns `{ passed: Boolean, checks: [...], final_states: {state => count}, unknown_transitions: Integer }` instead of true/false. The rake task exits 1 unless `result[:passed]`.

Run `bundle exec rspec` and, on the compose stack, `docker compose exec -T web bin/rails "chaos:run[10]"`. Expected: the same output and "The one rule held." Commit this move alone:

```bash
bin/check && git add app/lib/chaos_run.rb lib/tasks/chaos.rake && git commit -m "Move ChaosRun into app/lib so a job can drive it"
```

**Step 2: The job**

```ruby
# app/jobs/demo_chaos_run_job.rb
# typed: true
# frozen_string_literal: true

# D-04. Runs a small chaos run against the demo twin with a throwaway test
# key. ChaosRun makes the Nordpay simulator hostile for its duration, which
# also affects other demo payments made meanwhile; the UI says so.
class DemoChaosRunJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = DemoChaosRun.find(run_id)
    run.update!(state: "running")
    key, raw = ApiKey.issue!(merchant: DemoMerchant.live, livemode: false, name: "Demo chaos run #{run.id}")
    begin
      result = ChaosRun.new(payments: run.payments, merchant: DemoMerchant.twin, api_key: raw, out: StringIO.new).call
      run.update!(state: result[:passed] ? "passed" : "failed", result:, finished_at: Time.current)
    ensure
      key.revoke!
    end
  rescue StandardError => e
    run&.update!(state: "errored", error: e.class.name, finished_at: Time.current)
    raise
  end
end
```

Check that `ChaosRun` creates its payments through the HTTP API (it does; `@api` is `CHAOS_API_URL`). The job therefore needs the web service reachable from the worker. In compose, set `CHAOS_API_URL: http://web:3000` on the `worker` service.

`ChaosRun#call` waits up to `SETTLE_TIMEOUT` (300s). For a 20-payment demo that is acceptable in a background job; the UI polls `GET chaos_runs/:id`.

**Step 3: Controller**

- `create`: payments = `params[:payments].to_i.clamp(1, 20)`. Create the row with state `queued` (a unique violation becomes 409 `chaos_run_in_progress`, carrying the active run's id), then `DemoChaosRunJob.perform_later(run.id)`, then 202.
- `show`: the run's state, payments, result, error and timestamps.

Specs:
- A second create while one is active gives 409.
- A request for 50 payments is clamped to 20.
- `show` returns the result.
- Job spec: stub `ChaosRun#call` to return a passing result, then check the row becomes `passed` and the throwaway key is revoked even when `call` raises.

```bash
bin/check && git add app config spec docker-compose.yml && git commit -m "Run small chaos runs from the demo, one at a time"
```

---

### Task 8: Ledger summary (D-05) and reset (D-06)

**Ledger summary.** `Demo::Api::LedgerController#show`:
- entries for the twin since the epoch, grouped by `transfer_id`, newest 50 transfers;
- per transfer: legs (account kind, direction, amount), currency, and `nets_to_zero` (credits − debits == 0 per currency);
- plus `all_balanced: Ledger.unbalanced_transfer_ids & shown_ids == []`.

Query through `LedgerEntry.joins(:account).where(ledger_accounts: { merchant_id: twin.id })`. Check the association name and that `ledger_entries` has no `merchant_id` column (it does not; the account carries it).

**Reset.** `Demo::Api::ResetsController#create`:
- 429 `reset_too_soon` if the newest epoch started less than 1 minute ago;
- otherwise create a `DemoEpoch` with the request IP, then 201;
- refuse while a chaos run is active (409).

Specs:
- The summary shows only post-epoch transfers, and each nets to zero.
- A second reset within a minute gives 429.
- After a reset, `GET payments/:id` of an old payment gives 404.

```bash
bin/check && git add app config spec && git commit -m "Add the demo ledger summary and an epoch-based reset"
```

---

### Task 9: Abuse limits

In `config/initializers/rack_attack.rb`:

```ruby
  # Public demo (design §4): generous for a person, useless for a script.
  throttle("demo/ip", limit: 120, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/demo/api/")
  end

  throttle("demo/payments-ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/demo/api/payments"
  end
```

The one-active-chaos-run rule and the reset cooldown are enforced in the database and controller (Tasks 7 and 8), not here: Rack::Attack's cache is per process in test.

Spec in `spec/requests/demo/api/throttle_spec.rb`:
- enable Rack::Attack with a memory store for the example;
- 21 POSTs from one IP; the 21st gets 429 with `Retry-After`;
- reset the cache in `ensure`.

Check how existing throttle specs, if any, toggle `Rack::Attack.enabled` and follow them.

```bash
bin/check && git add config spec && git commit -m "Throttle the public demo per IP"
```

---

### Task 10: Demo pages

**Files:**
- Create: `app/frontend/demo/api.ts`, `router.ts`, `pages/Try.vue`, `pages/Chaos.vue`, `pages/Ledger.vue`, `components/StateDiagram.vue`, `components/ScenarioPicker.vue`
- Modify: `app/frontend/entrypoints/demo.ts`, `app/frontend/demo/App.vue`
- Test: `app/frontend/demo/components/StateDiagram.test.ts`

| Piece | Must |
|---|---|
| `ScenarioPicker.vue` | Five cards, each with the outcome in one sentence (e.g. "The PSP times out; its webhook arrives later and settles it") and the magic token shown, the way Stripe documents test cards. |
| `StateDiagram.vue` | SVG drawn from the generated `STATES` and `EDGES` (fixed hand-tuned coordinates for 9 states is fine). The current state is highlighted, visited states are marked from `timeline` transitions, and the edge just taken animates. Text labels on every node (not colour alone), and `aria-label` on the SVG summarising the current state and path. |
| `Try.vue` | Picker → `POST payments` → `useLiveQuery` with `pollIntervalFor` (Phase 1). Shows the diagram and the timeline. For `requires_action`: an "Approve in wallet" button. For `unknown` from `timeout_needs_operator`: explains that it will stay there until an operator resolves it, and links to the RUNBOOK section. The whole page carries a **"Test mode, simulated PSPs, no real money"** banner. |
| `Chaos.vue` | Size slider 1 to 20; start (409 shows "a run is in progress", then watches that run); polls `GET chaos_runs/:id`; lists each check with pass/fail and the final state counts. Notes that the Nordpay simulator is hostile while a run is active. |
| `Ledger.vue` | Transfers with legs, a "nets to zero ✓" per transfer, and the overall `all_balanced`. A Reset button (confirm dialog; 429 shows when it can be pressed again). |

`StateDiagram.test.ts`:
- Every generated edge is drawn (count the `path` elements with `data-edge`).
- The current node has `aria-current="step"`.

```bash
bin/check && git add app/frontend && git commit -m "Build the public demo pages with a live state diagram"
```

---

### Task 11: Playwright flow 3: `timeout_then_webhook` reaches `captured`

The demo needs the simulators and a worker, so this flow runs against the **compose stack**, not the Rails test server:

```ts
// e2e/demo.spec.ts
// Runs only when DEMO_E2E_BASE_URL is set (e.g. http://localhost:3000 after `docker compose up`).
// 1. Open /demo, pick "Timeout, then webhook", tick "capture immediately", create.
// 2. Expect the diagram to show `unknown` within 10s (the Nordpay timeout is 5s > PayHub's 3s).
// 3. Expect `authorized` or `captured` within 60s (webhook, or the sweeper's first poll after 2 min: allow 180s).
// 4. Expect the timeline to contain a transition from `unknown` with source `webhook` or `sweeper`.
```

Write it with `test.skip(!process.env.DEMO_E2E_BASE_URL, …)` and `use: { baseURL: process.env.DEMO_E2E_BASE_URL }`. In CI, add a step to the existing `chaos` job (which already runs the compose stack) after the chaos run:

```yaml
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: npm }
      - run: npm ci && npx playwright install --with-deps chromium
      - run: DEMO_E2E_BASE_URL=http://localhost:3000 npx playwright test e2e/demo.spec.ts
```

The step also needs the demo merchant seeded: `docker compose exec -T web bin/rails db:seed` before it (the chaos job currently runs `db:prepare` only).

```bash
bin/check && git add e2e .github/workflows/ci.yml && git commit -m "Add the demo timeout-then-webhook end-to-end test on the compose stack"
```

---

### Task 12: Decisions, README, verification

1. **DECISIONS #27: demo reset is a new epoch, not a delete.**
   - **Decision:** `demo_epochs`; the demo shows rows since the latest epoch.
   - **Rejected:** deleting the twin's data (the ledger and transitions are append-only by trigger); a fresh twin per reset (one twin per live merchant by unique index; changing that weakens test-mode separation for every merchant).
   - **Reason:** keeps every append-only guarantee; the old rows remain evidence.
2. **DECISIONS #28: magic tokens map onto the simulators' forced behaviours.**
   - **Decision:** each `tok_demo_*` token is a default `X-Sim-Force` list remembered on the charge.
   - **Rejected:** a separate deterministic simulator mode; amounts as magic values (Braintree style), which collide with real amounts in chaos runs.
   - **Reason:** one mechanism, already tested, and random chaos is untouched for every other token.
3. **README:** replace the "Chaos: run the one rule live" intro with a pointer to `/demo`, keeping the rake command for CI. Link each scenario to the DECISIONS entry it illustrates.
4. Verify:
   - `bin/check`, simulator specs, `npm run e2e`;
   - compose stack: `db:seed`, then `DEMO_E2E_BASE_URL=http://localhost:3000 npx playwright test e2e/demo.spec.ts`;
   - by hand, all five scenarios, a chaos run of 10, and a reset;
   - confirm the `timeout_needs_operator` payment appears in the ops queue (Phase 2) and can be resolved there by propose + approve;
   - then @superpowers:verification-before-completion and @superpowers:requesting-code-review.

```bash
bin/check && git add DECISIONS.md README.md && git commit -m "Record decisions #27-#28 and point the README at the live demo"
```
