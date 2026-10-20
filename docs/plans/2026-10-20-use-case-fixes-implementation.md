# Use-case audit fixes: implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Fix the 15 bugs in [USE_CASES.md](../USE_CASES.md) §1, including several partial captures (multicapture). Each fix is proven by the test cases in [TEST_CASES.md](../TEST_CASES.md) and must leave the existing 722-example suite green.

**Architecture:**
- Every fix is test-first against a TC id.
- PSP differences become **capability flags on the adapter**, so the domain never branches on a PSP name (DECISIONS #9). The new flags are `supports_multicapture?`, `supports_void?` and `idempotent_authorize?`.
- Rules that must hold even against a direct SQL write move into Postgres (triggers, CHECKs). Everything else stays in services under a row lock, as today.

**Tech stack:**
- Rails 8 API with Sorbet (`# typed:` and `sig`), RSpec, FactoryBot
- PostgreSQL with the SQL schema in `db/structure.sql`
- Sidekiq jobs (ActiveJob)
- Vue 3 front end (one text change)

**Overview:** [2026-10-20-use-case-fixes.md](2026-10-20-use-case-fixes.md) (lanes A/B/C, merge, phase 2).

---

## Conventions for every task

- **Test DB:** each lane has its own database.
  ```bash
  RAILS_ENV=test TEST_DATABASE=payhub_test_lane_x bin/rails db:create db:schema:load
  ```
  Prefix every command with `TEST_DATABASE=payhub_test_lane_x`.
- **Run one example:**
  ```bash
  TEST_DATABASE=… bundle exec rspec path/to/spec.rb -e "TC-E3-2"
  ```
- **Run the full suite:**
  ```bash
  TEST_DATABASE=… bundle exec rspec
  ```
  Expected: `N examples, 0 failures`, with N ≥ 722.
- **Type check:** `bundle exec srb tc`. Expected: `No errors! Great job.`
- **Spec names start with the TC id:** `it "TC-E3-2: …"`. That makes `rspec -e TC-E3` select a whole group.
- **Code comments** cite DECISIONS numbers, the way the existing code does.
- **Commits** are short and imperative, like the existing history.

**Helpers you will reuse:**
- `FakePspAdapter` (`spec/support/fake_psp_adapter.rb`): `script(:method, answers…)` queues answers; `calls[:method]` records the arguments it received.
- `create_merchant_with_key`, `auth_headers(key)` and `json_body` (`spec/support/api_helpers.rb`).
- `authorized_payment`, `captured_payment` and `charge(status, payment, captured_minor:)`, defined at the top of `spec/requests/v1/money_movement_spec.rb`.
- Specs that use real threads are tagged `:concurrency`. They run outside a transaction and are cleaned with `TRUNCATE` in replica mode (`spec/rails_helper.rb:33-47`), so the new triggers don't block cleanup.

---

## Task 0: capability flags (shared by every lane)

**Files:**
- Modify: `app/adapters/psp_adapter.rb` (the capability-flags block near the end)
- Modify: `app/adapters/nordpay_adapter.rb`, `app/adapters/kiripay_adapter.rb` (next to `supports_partial_refund?`)
- Modify: `spec/support/fake_psp_adapter.rb`
- Test: `spec/adapters/kiripay_adapter_spec.rb`, `spec/adapters/nordpay_adapter_spec.rb`

**Step 1: Write the failing tests**

```ruby
# spec/adapters/nordpay_adapter_spec.rb
it "declares multicapture, void and an idempotent authorize (DECISIONS #9, #12)" do
  expect(described_class.new).to have_attributes(
    supports_multicapture?: true, supports_void?: true, idempotent_authorize?: true
  )
end

# spec/adapters/kiripay_adapter_spec.rb
it "declares no multicapture, no void and a NON-idempotent authorize (DECISIONS #9, #12)" do
  expect(described_class.new).to have_attributes(
    supports_multicapture?: false, supports_void?: false, idempotent_authorize?: false
  )
end
```

**Step 2: Run, expect FAIL** with `NoMethodError: undefined method 'supports_multicapture?'`.

**Step 3: Implement**

```ruby
# app/adapters/psp_adapter.rb — append to "Capability flags"
# Several partial captures on one authorization (DECISIONS #20). Card-only in the market.
sig { abstract.returns(T::Boolean) }
def supports_multicapture?; end

# Can an uncaptured authorization be released (DECISIONS #14)?
sig { abstract.returns(T::Boolean) }
def supports_void?; end

# Does the PSP deduplicate a repeated authorize for the same reference?
# false means a second POST is a second charge (DECISIONS #12).
sig { abstract.returns(T::Boolean) }
def idempotent_authorize?; end
```

```ruby
# nordpay_adapter.rb
sig { override.returns(T::Boolean) }
def supports_multicapture? = true
sig { override.returns(T::Boolean) }
def supports_void? = true
sig { override.returns(T::Boolean) }
def idempotent_authorize? = true # honours X-Request-Id

# kiripay_adapter.rb
sig { override.returns(T::Boolean) }
def supports_multicapture? = false
sig { override.returns(T::Boolean) }
def supports_void? = false
sig { override.returns(T::Boolean) }
def idempotent_authorize? = false # a second POST is a second charge
```

```ruby
# spec/support/fake_psp_adapter.rb
def initialize(name: "nordpay", currencies: %w[EUR GBP USD], partial_refund: true, separate_auth: true,
               multicapture: true, void: true, idempotent_authorize: true)
  # …existing ivars…
  @multicapture = multicapture
  @void = void
  @idempotent_authorize = idempotent_authorize
end

def supports_multicapture? = @multicapture
def supports_void? = @void
def idempotent_authorize? = @idempotent_authorize
```

**Step 4: Run the adapter specs, then `bundle exec srb tc`.** Expected: PASS, no Sorbet errors.

**Step 5: Commit**

```bash
git add app/adapters spec/support/fake_psp_adapter.rb spec/adapters
git commit -m "Declare multicapture, void and idempotent-authorize capabilities per PSP"
```

---

# Lane A: money movement

## Task A1: multicapture columns (TC-E3-18)

**Files:**
- Create: `db/migrate/20261020000001_add_multicapture_to_payments_and_captures.rb`
- Modify: `db/structure.sql` (regenerated)
- Test: `spec/models/payment_spec.rb`

**Step 1: Failing test**

```ruby
it "TC-E3-18: has captures_closed_at, and captures default to final" do
  payment = create(:payment)
  expect(payment).to respond_to(:captures_closed_at)
  expect(payment.captures.new(amount_minor: 1, base_captured_minor: 0).final).to be(true)
end
```

**Step 2: Run, expect FAIL** (`NoMethodError: captures_closed_at`).

**Step 3: Migration**

```ruby
class AddMulticaptureToPaymentsAndCaptures < ActiveRecord::Migration[8.0]
  def up
    add_column :payments, :captures_closed_at, :datetime
    add_column :captures, :final, :boolean, null: false, default: true
    # Before this change the first partial capture was final (DECISIONS #20).
    # Close every payment that already took money, so none reopens.
    execute <<~SQL
      UPDATE payments SET captures_closed_at = now()
      WHERE state IN ('captured', 'part_refunded', 'refunded')
    SQL
  end

  def down
    remove_column :captures, :final
    remove_column :payments, :captures_closed_at
  end
end
```

**Step 4: Migrate and check the dump**

```bash
TEST_DATABASE=… RAILS_ENV=test bin/rails db:migrate
git diff --stat db/structure.sql   # expect 2 new columns + schema_migrations row
TEST_DATABASE=… bundle exec rspec spec/models/payment_spec.rb -e TC-E3-18
```

Expected: PASS.

**Step 5: Commit** `"Add captures_closed_at and captures.final"`.

## Task A2: `Payment#capturing_open?` and `#close_captures!`

**Files:**
- Modify: `app/models/payment.rb`
- Test: `spec/models/payment_spec.rb`

**Step 1: Failing tests**

```ruby
describe "capturing (DECISIONS #20)" do
  let(:payment) { create(:payment).tap { |p| p.transition!(:authorized, sort_key: p.created_at + 1, source: "worker") } }

  it "is open while authorized or partly captured, and money remains" do
    expect(payment.capturing_open?).to be(true)
    Ledger.record_capture!(payment, 2500)
    expect(payment.capturing_open?).to be(false) # fully captured: nothing left
  end

  it "close_captures! stamps the payment and announces it" do
    Ledger.record_capture!(payment, 1000)
    payment.transition!(:captured, sort_key: payment.created_at + 2, source: "worker")
    payment.close_captures!(reason: "final_capture", source: "api")
    expect(payment.reload.captures_closed_at).to be_present
    expect(OutboundEvent.where(payment:, event_type: "payment.captures_closed").count).to eq(1)
  end

  it "close_captures! on a fully refunded part_refunded payment moves it to refunded" do
    Ledger.record_capture!(payment, 1000)
    payment.transition!(:captured, sort_key: payment.created_at + 2, source: "worker")
    allow(Ledger).to receive(:refunded_minor).with(payment).and_return(1000)
    payment.transition!(:part_refunded, sort_key: payment.created_at + 3, source: "worker")
    payment.close_captures!(reason: "final_capture", source: "api")
    expect(payment.reload.state).to eq("refunded")
  end
end
```

**Step 2: Run, expect FAIL** (`NoMethodError: capturing_open?`).

**Step 3: Implement**

```ruby
# app/models/payment.rb
CAPTURABLE_STATES = %w[authorized captured part_refunded].freeze

# More money may still be taken: the payment holds a hold, no final capture
# has been made, and the authorization isn't used up (DECISIONS #20).
sig { returns(T::Boolean) }
def capturing_open?
  CAPTURABLE_STATES.include?(state) && captures_closed_at.nil? && Ledger.captured_minor(self) < amount_minor
end

sig { returns(Integer) }
def capturable_minor = capturing_open? ? amount_minor - Ledger.captured_minor(self) : 0

# No more captures. The uncaptured remainder lapses at the network: PayHub
# does not release it at the PSP (DECISIONS #14, "Not handled"). A payment
# whose captured money is already all refunded ends here.
sig { params(reason: String, source: String).void }
def close_captures!(reason:, source:)
  with_lock do
    next if captures_closed_at

    update_columns(captures_closed_at: Time.current)
    OutboundEvent.emit!(self, "payment.captures_closed", "reason" => reason)
    if state == "part_refunded" && Ledger.refunded_minor(self) >= Ledger.captured_minor(self)
      transition!(:refunded, sort_key: Time.current, source:, metadata: { "reason" => reason })
    end
  end
end
```

**Step 4: Run, expect PASS.** **Step 5: Commit** `"Track whether a payment can still be captured"`.

## Task A3: `CapturePayment` accepts several captures (TC-E3-1…11, 17)

**Files:**
- Modify: `app/services/capture_payment.rb` (whole `call`)
- Modify: `app/controllers/v1/payments_controller.rb:46-51` (read `final`)
- Modify: `app/controllers/dashboard/api/payments_controller.rb` (the capture action; the same `final` param)
- Modify: `app/services/cancel_payment.rb:47-53` (better message, TC-E3-17)
- Test: `spec/requests/v1/money_movement_spec.rb`

**Step 1: Failing tests.** Add to `describe "POST /v1/payments/:id/capture"`:

```ruby
def capture!(payment, body)
  post "/v1/payments/#{payment.id}/capture", params: body.to_json, headers: auth_headers(key)
end

def land!(payment, amount) # what CapturePaymentJob does when the PSP agrees
  capture = payment.captures.pending.sole
  Ledger.record_capture!(payment, amount)
  payment.update_column(:captured_minor, Ledger.captured_minor(payment))
  payment.transition!(:captured, sort_key: Time.current, source: "worker") if payment.state == "authorized"
  capture.update!(state: "succeeded")
  payment.close_captures!(reason: "final_capture", source: "worker") if capture.final
end

it "TC-E3-1/2: a non-final capture keeps the payment capturable; a second capture is accepted" do
  payment = authorized_payment
  capture!(payment, amount_minor: 1000, final: false)
  expect(response).to have_http_status(:accepted)
  land!(payment, 1000)
  expect(payment.reload).to have_attributes(state: "captured", captures_closed_at: nil, capturable_minor: 1500)

  capture!(payment, amount_minor: 1500)
  expect(response).to have_http_status(:accepted)
  land!(payment, 1500)
  expect(Ledger.captured_minor(payment)).to eq(2500)
  expect(payment.reload.captures_closed_at).to be_present
end

it "TC-E3-3: a default (final) partial capture closes capturing" do
  payment = authorized_payment
  capture!(payment, amount_minor: 1000)
  land!(payment, 1000)
  capture!(payment, amount_minor: 500)
  expect(response).to have_http_status(:bad_request)
  expect(json_body["error"]["code"]).to eq("capture_closed")
end

it "TC-E3-4: the captures together can never exceed authorized" do
  payment = authorized_payment
  capture!(payment, amount_minor: 1000, final: false)
  land!(payment, 1000)
  capture!(payment, amount_minor: 2000)
  expect(response).to have_http_status(:unprocessable_content)
  expect(json_body["error"]["details"]["amount_minor"].first).to include("between 1 and 1500")
end

it "TC-E3-5: a zero-amount final capture closes the remainder without calling the PSP" do
  payment = authorized_payment
  capture!(payment, amount_minor: 1000, final: false)
  land!(payment, 1000)
  capture!(payment, amount_minor: 0, final: true)
  expect(response).to have_http_status(:ok)
  expect(payment.reload.captures_closed_at).to be_present
  expect(payment.captures.count).to eq(1)
  expect(adapter.calls[:capture]).to be_empty
end

it "TC-E3-6: a zero-amount capture with nothing captured is refused" do
  capture!(authorized_payment, amount_minor: 0, final: true)
  expect(response).to have_http_status(:bad_request)
  expect(json_body["error"]["message"]).to include("use cancel")
end

it "TC-E3-10: multicapture is refused on a PSP without it" do
  allow(adapter).to receive(:supports_multicapture?).and_return(false)
  capture!(authorized_payment, amount_minor: 1000, final: false)
  expect(response).to have_http_status(:bad_request)
  expect(json_body["error"]["code"]).to eq("multicapture_unsupported")
end

it "TC-E3-11: at most 50 non-final captures; a final one is still allowed" do
  payment = authorized_payment
  50.times { payment.captures.create!(amount_minor: 1, base_captured_minor: 0, final: false, state: "succeeded") }
  Ledger.record_capture!(payment, 50)
  payment.transition!(:captured, sort_key: Time.current, source: "worker")
  capture!(payment, amount_minor: 1, final: false)
  expect(json_body["error"]["code"]).to eq("capture_limit_reached")
  capture!(payment, amount_minor: 1)
  expect(response).to have_http_status(:accepted)
end

it "TC-E3-17: cancel after a partial capture points at the zero-amount final capture" do
  payment = captured_payment(1000)
  post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)
  expect(json_body["error"]["message"]).to include("zero-amount final capture")
end
```

**Step 2: Run** `rspec spec/requests/v1/money_movement_spec.rb -e TC-E3`. Expected: FAIL. E3-1/2 fail with 400 `invalid_state`, and the others fail with an unknown code.

**Step 3: Implement**

```ruby
# app/services/capture_payment.rb
class CapturePayment
  extend T::Sig

  # Stripe's limit: 50 non-final captures plus one final (DECISIONS #20).
  MAX_NON_FINAL = 50

  sig { params(payment: Payment, amount_minor: T.nilable(Integer), final: T::Boolean).returns(Payment) }
  def self.call(payment, amount_minor: nil, final: true)
    payment.with_lock do
      assert_capturable!(payment)
      already = Ledger.captured_minor(payment)
      remaining = payment.amount_minor - already
      adapter = PspRouter.adapter(payment.psp_name)

      next close!(payment, already) if amount_minor&.zero? && final

      amount = amount_minor || remaining
      if amount <= 0 || amount > remaining
        raise ApiError.validation("amount_minor" => ["must be between 1 and #{remaining} (authorized #{payment.amount_minor}, captured #{already})"])
      end
      if amount < remaining && !adapter.separate_authorize_and_capture?
        raise ApiError.invalid_request("#{payment.psp_name} does not support partial capture",
                                       code: "partial_capture_unsupported", param: "amount_minor")
      end
      if !final && !adapter.supports_multicapture?
        raise ApiError.invalid_request("#{payment.psp_name} does not support several captures; omit final or set it to true",
                                       code: "multicapture_unsupported", param: "final")
      end
      if !final && payment.captures.where(final: false).where.not(state: "failed").count >= MAX_NON_FINAL
        raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 422, code: "capture_limit_reached",
                           message: "At most #{MAX_NON_FINAL} non-final captures; send a final capture", param: "final")
      end
      assert_none_in_flight!(payment)

      capture = payment.captures.create!(amount_minor: amount, base_captured_minor: already, final:)
      # A capture request restarts the hold clock (DECISIONS #14).
      payment.touch
      CapturePaymentJob.perform_later(capture.id)
    end
    payment
  end

  sig { params(payment: Payment).void }
  def self.assert_capturable!(payment)
    unless Payment::CAPTURABLE_STATES.include?(payment.state)
      raise ApiError.invalid_request("Payment is #{payment.state}; only authorized or partly captured payments can be captured",
                                     code: "invalid_state", param: "id")
    end
    return if payment.captures_closed_at.nil?

    raise ApiError.invalid_request("The final capture has been made; no more can be taken",
                                   code: "capture_closed", param: "id")
  end

  sig { params(payment: Payment).void }
  def self.assert_none_in_flight!(payment)
    return unless payment.captures.pending.exists?

    raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "capture_in_progress",
                       message: "A capture for this payment is still in flight; retry when it settles",
                       param: "id", retriable: true)
  end

  # amount 0 + final: stop capturing, take nothing more (Stripe amount_to_capture=0).
  sig { params(payment: Payment, already: Integer).returns(Payment) }
  def self.close!(payment, already)
    if already.zero?
      raise ApiError.invalid_request("Nothing has been captured; use cancel to release the hold",
                                     code: "invalid_request", param: "amount_minor")
    end
    assert_none_in_flight!(payment)
    payment.close_captures!(reason: "final_capture", source: "api")
    payment
  end
end
```

The v1 controller reads `final`:

```ruby
def capture
  payment = current_merchant.payments.find(params[:id])
  final = params.key?(:final) ? params[:final] : true
  raise ApiError.validation("final" => ["must be true or false"]) unless [true, false].include?(final)

  amount = optional_amount
  CapturePayment.call(payment, amount_minor: amount, final:)
  # A zero-amount final capture moves no money: 200, not 202.
  render json: PaymentSerializer.call(payment.reload), status: amount&.zero? ? :ok : :accepted
end
```

Check `optional_amount` (`payments_controller.rb:~65`). It currently rejects 0 ("must be a positive integer when present"). Allow 0 and let `CapturePayment` validate it.

Change the `assert_authorized!` message in `cancel_payment.rb` when the payment took money:

```ruby
hint = Ledger.captured_minor(payment).positive? ? "; to release the rest, send a zero-amount final capture" : ""
raise ApiError.invalid_request("Payment is #{payment.state}; only authorized payments can be canceled#{hint}", …)
```

**Step 4: Run `-e TC-E3`, then the whole money_movement spec.** Expected: PASS. The old spec "rejects capture of a pending payment with invalid_state" stays green.

**Step 5: Commit** `"Allow several partial captures with a final flag"`.

## Task A4: `CapturePaymentJob` closes on final and announces each capture (TC-E3-12, 13, 14)

**Files:**
- Modify: `app/jobs/capture_payment_job.rb:33` (states) and `finish`
- Test: `spec/jobs/capture_payment_job_spec.rb`

**Step 1: Failing tests**

```ruby
it "TC-E3-12: one capture.succeeded per capture, payment.captured once, final closes" do
  first = payment.captures.create!(amount_minor: 1000, base_captured_minor: 0, final: false)
  adapter.script(:fetch, charge(:authorized, captured_minor: 0))
  adapter.script(:capture, charge(:authorized, captured_minor: 1000))
  described_class.perform_now(first.id)
  expect(payment.reload.captures_closed_at).to be_nil

  second = capture_request(1500) # final by default
  adapter.script(:fetch, charge(:authorized, captured_minor: 1000))
  adapter.script(:capture, charge(:captured, captured_minor: 2500))
  described_class.perform_now(second.id)

  events = OutboundEvent.where(payment:)
  expect(events.where(event_type: "capture.succeeded").map { _1.payload["capture"]["amount_minor"] }).to eq([1000, 1500])
  expect(events.where(event_type: "capture.succeeded").map { _1.payload["capture"]["capturable_minor"] }).to eq([1500, 0])
  expect(events.where(event_type: "payment.captured").count).to eq(1)
  expect(payment.reload.captures_closed_at).to be_present
end

it "TC-E3-13: a rejected capture emits capture.failed and leaves capturing open" do
  capture = capture_request(1000)
  adapter.script(:fetch, charge(:authorized, captured_minor: 0))
  adapter.script(:capture, PspAdapter::Rejected.new(422, "nope"))
  described_class.perform_now(capture.id)
  expect(capture.reload.state).to eq("failed")
  failed = OutboundEvent.find_by(payment:, event_type: "capture.failed")
  expect(failed.payload["capture"]).to include("failure_code" => "psp_rejected_422")
  expect(payment.reload.captures_closed_at).to be_nil
end

it "TC-E3-8 (job side): a capture runs on a part_refunded payment" do
  first = payment.captures.create!(amount_minor: 1000, base_captured_minor: 0, final: false)
  adapter.script(:fetch, charge(:authorized, captured_minor: 0), charge(:authorized, captured_minor: 1000))
  adapter.script(:capture, charge(:authorized, captured_minor: 1000), charge(:captured, captured_minor: 2500))
  described_class.perform_now(first.id)
  payment.transition!(:part_refunded, sort_key: Time.current, source: "worker")
  described_class.perform_now(capture_request(1500).id)
  expect(Ledger.captured_minor(payment)).to eq(2500)
end
```

**Step 2: Run, expect FAIL.** There is no `capture.succeeded`, and on `part_refunded` the result is "payment_part_refunded failed".

**Step 3: Implement**

```ruby
# perform
unless Payment::CAPTURABLE_STATES.include?(payment.state)
  return finish(capture, "failed", failure_code: "payment_#{payment.state}")
end

# finish — announce every capture and close on a final one (DECISIONS #20)
sig { params(capture: Capture, state: String, failure_code: T.nilable(String)).void }
def finish(capture, state, failure_code: nil)
  payment = T.must(capture.payment)
  payment.with_lock do
    capture.reload
    next unless capture.state == "pending"

    capture.update!(state: state, failure_code: failure_code)
    payment.update_columns(captures_closed_at: Time.current) if state == "succeeded" && capture.final
    OutboundEvent.emit!(payment, "capture.#{state}", "capture" => {
      "id" => capture.id, "amount_minor" => capture.amount_minor, "final" => capture.final,
      "failure_code" => failure_code, "capturable_minor" => payment.reload.capturable_minor
    })
  end
end
```

**Step 4: Run the full job spec.** Expected: PASS, including the old "never capturing twice" examples (TC-E3-14).

**Step 5: Commit** `"Announce each capture and close capturing on the final one"`.

## Task A5: refunds between captures (TC-E3-8, 9)

**Files:**
- Modify: `app/jobs/refund_payment_job.rb:54` (the `to =` line)
- Test: `spec/jobs/refund_payment_job_spec.rb`

**Step 1: Failing test**

```ruby
it "TC-E3-9: refunding everything captured while capturing is open is part_refunded, not refunded" do
  payment = create(:payment).tap { |p| p.transition!(:authorized, sort_key: p.created_at + 1, source: "worker") }
  Ledger.record_capture!(payment, 1000)
  payment.transition!(:captured, sort_key: payment.created_at + 2, source: "worker")
  refund = CreateRefund.call(payment, amount_minor: 1000, reason: "x")
  adapter.script(:refund, refund_result(:succeeded, refund))
  RefundPaymentJob.perform_now(refund.id)
  expect(payment.reload.state).to eq("part_refunded")

  payment.close_captures!(reason: "final_capture", source: "api")
  expect(payment.reload.state).to eq("refunded")
end
```

Copy `refund_result` and the `CreateRefund` signature from the existing helpers in this spec file.

**Step 2: Run, expect FAIL.** It ends `refunded` immediately.

**Step 3: Implement**

```ruby
# Fully refunded only when nothing more can be captured (Stripe multicapture:
# charge.refunded only after the final capture).
fully = Ledger.refunded_minor(payment) >= Ledger.captured_minor(payment) && !payment.reload.capturing_open?
to = fully ? :refunded : :part_refunded
```

**Step 4: Run the full refund spec, expect PASS.** **Step 5: Commit** `"Keep a payment open for capture while refunds catch up"`.

## Task A6: idle expiry closes open remainders and skips non-voidable PSPs (TC-E3-16, TC-G6-4)

**Files:**
- Modify: `app/jobs/expire_authorizations_job.rb` (`perform`)
- Test: `spec/jobs/expire_authorizations_job_spec.rb`

**Step 1: Failing tests**

```ruby
it "TC-E3-16: a partly captured payment idle for 6 days is closed, not voided" do
  payment = create(:payment).tap { |p| p.transition!(:authorized, sort_key: p.created_at + 1, source: "worker") }
  Ledger.record_capture!(payment, 1000)
  payment.transition!(:captured, sort_key: payment.created_at + 2, source: "worker")
  payment.update_column(:updated_at, 7.days.ago)
  described_class.perform_now
  expect(payment.reload).to have_attributes(state: "captured", captures_closed_at: be_present)
  expect(adapter.calls[:cancel]).to be_empty
  expect(OutboundEvent.where(payment:, event_type: "payment.captures_closed").sole.payload["reason"]).to eq("authorization_expired")
end

it "TC-G6-4: PSPs that cannot void are skipped" do
  allow(adapter).to receive(:supports_void?).and_return(false)
  payment = create(:payment).tap { |p| p.transition!(:authorized, sort_key: p.created_at + 1, source: "worker") }
  payment.update_column(:updated_at, 7.days.ago)
  described_class.perform_now
  expect(payment.reload.state).to eq("authorized")
  expect(adapter.calls[:cancel]).to be_empty
end
```

**Step 2: Run, expect FAIL.**

**Step 3: Implement**

```ruby
def perform
  now = Time.current
  idle = Payment.where(updated_at: ..(now - HOLD_LIMIT)).where.not(id: Capture.pending.select(:payment_id))

  voidable = Payment::PSPS.select { |psp| PspRouter.adapter(psp).supports_void? }
  skipped = idle.where(state: "authorized").where.not(psp_name: voidable).count
  Rails.logger.info({ event: "authorization.expiry_unsupported", count: skipped }.to_json) if skipped.positive?

  idle.where(state: "authorized", psp_name: voidable)
      .where("next_check_at IS NULL OR next_check_at <= ?", now)
      .order(:updated_at).limit(BATCH).each { |payment| expire(payment, now) }

  # Partly captured and still open: stop capturing; the remainder lapses at
  # the network (DECISIONS #14). Nothing to void — money already moved.
  idle.where(state: %w[captured part_refunded], captures_closed_at: nil)
      .order(:updated_at).limit(BATCH)
      .each { |payment| payment.close_captures!(reason: "authorization_expired", source: "sweeper") }
end
```

**Step 4: Run the expiry spec, expect PASS.** **Step 5: Commit** `"Close open capture remainders after 6 idle days"`.

## Task A7: actions and serializer show what can be captured (TC-E3-1, TC-G6-3)

**Files:**
- Modify: `app/services/payment_actions.rb`
- Modify: `app/serializers/payment_serializer.rb`
- Test: `spec/services/payment_actions_spec.rb`, `spec/requests/v1/payments_spec.rb`

**Step 1: Failing tests**

```ruby
# payment_actions_spec.rb
it "TC-E3-1: a partly captured, open payment can still be captured" do
  Ledger.record_capture!(payment, 1000)
  payment.transition!(:captured, sort_key: Time.current, source: "worker")
  expect(described_class.call(payment, granted: ->(_) { true })).to include("capture" => true, "capturable_minor" => 1500)
end

it "TC-G6-3: no cancel on a PSP that cannot void" do
  allow(PspRouter).to receive(:adapter).and_return(FakePspAdapter.new(void: false))
  expect(described_class.call(payment, granted: ->(_) { true })["cancel"]).to be(false)
end

# v1/payments_spec.rb
it "TC-E3-1: GET shows amount_capturable_minor" do
  get "/v1/payments/#{payment.id}", headers: auth_headers(key)
  expect(json_body).to include("amount_capturable_minor" => 2500)
end
```

**Step 2: Run, expect FAIL.**

**Step 3: Implement**

```ruby
# payment_actions.rb
capturable = payment.capturable_minor
voidable = PspRouter.adapter(payment.psp_name).supports_void?
{
  "capture" => granted.call("payments.capture") && capturable.positive? && !payment.captures.pending.exists?,
  "cancel" => granted.call("payments.cancel") && payment.state == "authorized" && captured.zero? && voidable,
  # …refund unchanged…
  "capturable_minor" => capturable,
}

# payment_serializer.rb — next to captured_minor
"amount_capturable_minor" => payment.capturable_minor,
```

**Step 4: Run both specs, expect PASS.** **Step 5: Commit** `"Expose what is left to capture"`.

## Task A8: webhook capture books the PSP's amount; late success is loud (TC-E11-1, TC-E3-15, TC-B3-3)

**Files:**
- Modify: `app/jobs/process_inbound_event_job.rb` (`perform` and `apply`)
- Create: `spec/jobs/process_inbound_event_job_spec.rb`

**Step 1: Failing tests**

```ruby
require "rails_helper"

RSpec.describe ProcessInboundEventJob do
  let(:payment) { create(:payment).tap { |p| p.transition!(:authorized, sort_key: p.created_at + 1, source: "worker") } }
  let(:adapter) { FakePspAdapter.new }

  before { allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter) }

  def inbound(status:, captured_minor:, at: Time.current)
    data = { "reference" => payment.psp_reference, "status" => status.to_s, "captured_minor" => captured_minor }
    event = InboundEvent.create!(psp_name: "nordpay", external_id: SecureRandom.hex(4), event_type: "charge.#{status}",
                                 psp_reference: payment.psp_reference, signature_valid: true, received_at: at,
                                 payload: { "data" => data })
    adapter.script(:parse_webhook, PspAdapter::WebhookEvent.new(
      external_id: event.external_id, event_type: event.event_type, psp_reference: payment.psp_reference,
      psp_charge_id: "ch_1", status: PspAdapter::Result::Status.deserialize(status.to_s), decline_code: nil,
      psp_timestamp: at, payload: event.payload
    ))
    event
  end

  it "TC-E11-1: books the PSP's running total, not the authorized amount" do
    Ledger.record_capture!(payment, 1000)
    payment.transition!(:captured, sort_key: payment.created_at + 2, source: "worker")
    described_class.perform_now(inbound(status: :captured, captured_minor: 1000).id)
    expect(Ledger.captured_minor(payment)).to eq(1000)
  end

  it "TC-E3-15: an 'authorized, captured 1000' event on a captured payment is progress, not an error" do
    Ledger.record_capture!(payment, 1000)
    payment.transition!(:captured, sort_key: payment.created_at + 2, source: "worker")
    event = inbound(status: :authorized, captured_minor: 1000, at: payment.created_at + 3)
    described_class.perform_now(event.id)
    expect(event.reload).to have_attributes(processed_at: be_present, error: nil)
    expect(payment.reload.state).to eq("captured")
  end

  it "TC-B3-3: a success webhook on a failed payment is recorded loudly and changes nothing" do
    failed = create(:payment).tap { |p| p.transition!(:failed, sort_key: p.created_at + 1, source: "sweeper") }
    allow(payment).to receive(:psp_reference).and_return(failed.psp_reference)
    event = inbound(status: :captured, captured_minor: 2500)
    event.update_columns(psp_reference: failed.psp_reference)
    expect(Metrics).to receive(:increment).with(:late_success, psp: "nordpay").and_call_original
    described_class.perform_now(event.id)
    expect(event.reload.error).to include("late success")
    expect(failed.reload.state).to eq("failed")
    expect(Ledger.captured_minor(failed)).to eq(0)
  end
end
```

Check the `InboundEvent` column names against `db/structure.sql` (`CREATE TABLE public.inbound_events`) before running.

**Step 2: Run, expect FAIL.**
- E11-1 books 2500.
- E3-15 records an illegal-transition error.
- B3-3 raises, or records a generic error.

**Step 3: Implement**

```ruby
# perform — next to the IllegalTransition rescue
rescue LateSuccess => e
  event.update!(processed_at: Time.current, error: e.message)
  Metrics.increment(:late_success, psp: event.psp_name)
  Rails.logger.error({ event: "webhook.late_success_after_failure", inbound_event_id: event.id,
                       payment_id: payment.id }.to_json)

# a PSP says "money taken" for a payment we already failed (customer action
# expired, never received). Never book it silently; a human refunds it.
class LateSuccess < StandardError; end

# apply
captured = parsed.payload.dig("data", "captured_minor")&.to_i
if %w[authorized captured].include?(status.serialize) && payment.reload.state == "failed"
  raise LateSuccess, "late success: PSP reports #{status.serialize} on a failed payment"
end

case status
when PspAdapter::Result::Status::Authorized
  if captured.to_i.positive? && %w[captured part_refunded].include?(payment.state)
    # Nordpay keeps a partly captured charge "authorized" (DECISIONS #20).
    BookCapture.call(payment, psp_captured_minor: captured, psp_timestamp: ts, source: "webhook", metadata: meta)
  else
    move(payment, :authorized, ts, meta)
  end
when PspAdapter::Result::Status::Captured
  # …existing synthetic-authorized step…
  # The PSP's running total when it says so; Kiripay is full-capture only.
  BookCapture.call(payment, psp_captured_minor: captured || payment.amount_minor, psp_timestamp: ts,
                            source: "webhook", metadata: meta)
```

**Step 4: Run the new spec and `spec/requests/v1/webhooks_spec.rb`.** Expected: PASS (TC-E11-2 included).

**Step 5: Commit** `"Book webhook captures from the PSP's total and flag late successes"`.

## Task A9: a rejected refund fails and releases its money (TC-BUG2-1, 2)

**Files:**
- Modify: `app/jobs/refund_payment_job.rb:16-35`
- Test: `spec/jobs/refund_payment_job_spec.rb`

**Step 1: Failing test**

```ruby
it "TC-BUG2-1: a Rejected refund is failed, its reservation voided, and the merchant told" do
  refund = CreateRefund.call(payment, amount_minor: 1000, reason: "x") # payment captured 2500
  adapter.script(:refund, PspAdapter::Rejected.new(404, "charge not found"))
  described_class.perform_now(refund.id)
  expect(refund.reload).to have_attributes(state: "failed", failure_code: "psp_rejected_404")
  expect(Ledger.reserved_minor(payment)).to eq(0)
  expect(OutboundEvent.where(payment:, event_type: "refund.failed").count).to eq(1)
  expect(payment.reload.state).to eq("captured")
end
```

If `refunds` has no `failure_code` column, check `structure.sql` and assert on the event payload instead.

**Step 2: Run, expect FAIL.** The refund stays `pending`.

**Step 3: Implement.** Remove `discard_on PspAdapter::Rejected`, then:

```ruby
result = begin
  adapter.refund(refund)
rescue PspAdapter::TimedOut
  adapter.fetch_refund(refund.psp_reference)
rescue PspAdapter::Rejected => e
  # The PSP refused for good. Leaving it pending would hold the merchant's
  # money in refunds_reserved forever (DECISIONS #16): fail it and release.
  PspAdapter::RefundResult.new(status: PspAdapter::RefundResult::Status::Failed, psp_reference: refund.psp_reference,
                               psp_refund_id: nil, failure_code: "psp_rejected_#{e.http_status}",
                               psp_timestamp: Time.current)
end
```

In the `Failed` branch, persist the code if the column exists: `refund.update!(state: "failed", failure_code: result.failure_code)`.

**Step 4: Run the full refund spec, expect PASS.** **Step 5: Commit** `"Fail rejected refunds and release their reservation"`.

## Task A10: cancel on a PSP that can't void, and PSP rejections as 4xx (TC-G6-1, 2)

**Files:**
- Modify: `app/services/cancel_payment.rb` (preflight)
- Modify: `app/controllers/v1/base_controller.rb`, `app/controllers/dashboard/api/base_controller.rb` (`rescue_from`)
- Test: `spec/requests/v1/money_movement_spec.rb`

**Step 1: Failing tests**

```ruby
it "TC-G6-1: cancel on a PSP that cannot void is refused before any call" do
  allow(adapter).to receive(:supports_void?).and_return(false)
  post "/v1/payments/#{authorized_payment.id}/cancel", params: "{}", headers: auth_headers(key)
  expect(response).to have_http_status(:bad_request)
  expect(json_body["error"]["code"]).to eq("cancel_unsupported")
  expect(adapter.calls[:cancel]).to be_empty
end

it "TC-G6-2: a PSP refusal becomes 409 psp_rejected, not 500" do
  payment = authorized_payment
  adapter.script(:cancel, PspAdapter::Rejected.new(409, "not_voidable"))
  post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)
  expect(response).to have_http_status(:conflict)
  expect(json_body["error"]).to include("code" => "psp_rejected", "retriable" => false)
  expect(payment.reload.state).to eq("authorized")
end
```

**Step 2: Run, expect FAIL.** It returns a 500.

**Step 3: Implement**

```ruby
# cancel_payment.rb, after the first with_lock
adapter = PspRouter.adapter(payment.psp_name)
unless adapter.supports_void?
  raise ApiError.invalid_request("#{payment.psp_name} cannot release a hold; refund after capture instead",
                                 code: "cancel_unsupported", param: "id")
end

# v1/base_controller.rb and dashboard/api/base_controller.rb, beside the Unavailable rescue
rescue_from PspAdapter::Rejected do |e|
  T.bind(self, V1::BaseController) # Dashboard::Api::BaseController in the dashboard file
  render_api_error(ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "psp_rejected",
                                message: "The PSP refused: #{e.message}", retriable: false))
end
```

**Step 4: Run `-e TC-G6`, expect PASS.** **Step 5: Commit** `"Refuse cancels a PSP cannot do, and report PSP refusals as 409"`.

## Task A11: the simulation exercises multicapture (TC-E3-19)

**Files:**
- Modify: `spec/support/payment_simulation.rb` (the capture action near line 116 and the summary)
- Modify: `spec/simulation/payment_simulation_spec.rb`

**Step 1:**
- Change the capture action to `final: rng.rand < 0.5`.
- Count outcomes in `@outcomes[[:capture, code]] += 1`. Use `:accepted` on success and the ApiError `code` on rescue.
- Add this assertion after the run:

```ruby
expect(sim.outcomes.keys.map(&:last)).to all(be_in(%i[accepted] + %w[invalid_state capture_closed capture_in_progress validation_error]))
expect(sim.second_captures_accepted).to be_positive # a payment got ≥ 2 succeeded captures
```

**Step 2:** Run it on master first (`git stash`). It should fail on `second_captures_accepted == 0`, which reproduces bug 3. Then run it on the branch: PASS for all 20 seeds.

**Step 3: Commit** `"Make the simulation take several captures and count refusals"`.

## Task A12: docs and UI text

**Files:**
- Modify: `DECISIONS.md`:
  - **#20:** multicapture semantics. Add the market refs: [Stripe multicapture](https://docs.stripe.com/payments/multicapture), [Checkout.com capture](https://www.checkout.com/docs/payments/manage-payments/capture-a-payment), [Adyen capture](https://docs.adyen.com/online-payments/capture).
  - **#14:** remainders are closed at idle expiry. Keep the "Not handled" PSP-side release.
  - **#9:** the three capabilities.
- Modify: `docs/DOMAIN.md`:
  - captures section: `final`, `captures_closed_at`
  - walkthrough step 9: "Letters to send +2 (`payment.part_refunded`, `refund.succeeded`)"
  - step 6: add `capture.succeeded`
- Modify: `app/frontend/merchant/components/CaptureDialog.vue:51`. Replace "the rest of the authorization is released later" with "The rest of the hold is not collected. Your customer's bank releases it within about 7 days."
- Modify: `README.md`, wherever it documents capture params and errors: `final`, `capture_closed`, `multicapture_unsupported`, `capture_limit_reached`, `cancel_unsupported`, `psp_rejected`.

Run `npx vitest run app/frontend/merchant` if a CaptureDialog test asserts on the text.

**Commit** `"Document multicapture and the new capabilities"`.

---

# Lane B: recovery

## Task B1: never re-POST to a non-idempotent PSP (TC-B7-1, 2, 4, TC-B8-2)

**Files:**
- Modify: `app/services/resolve_unknown_payment.rb`
- Create: `spec/services/resolve_unknown_payment_spec.rb`

**Step 1: Failing tests**

```ruby
require "rails_helper"

RSpec.describe ResolveUnknownPayment do
  let(:kiripay) { FakePspAdapter.new(name: "kiripay", currencies: %w[VND], idempotent_authorize: false) }
  let(:payment) { create(:payment, :vnd) }

  def not_found = PspAdapter::Result.new(status: PspAdapter::Result::Status::NotFound, psp_reference: payment.psp_reference,
                                         psp_charge_id: nil, decline_code: nil, psp_timestamp: Time.current)

  it "TC-B7-1: a sent Kiripay payment is never re-POSTed after not-found" do
    payment.mark_sent!
    kiripay.script(:fetch, not_found)
    expect(described_class.call(payment, kiripay)).to be_nil
    expect(kiripay.calls[:authorize]).to be_empty
  end

  it "TC-B7-4: after the lookup grace it is failed as never received" do
    payment.mark_sent!
    payment.update_column(:first_sent_at, 31.minutes.ago)
    kiripay.script(:fetch, not_found)
    result = described_class.call(payment, kiripay)
    expect(result).to have_attributes(status: PspAdapter::Result::Status::Declined, decline_code: "psp_never_received")
    expect(kiripay.calls[:authorize]).to be_empty
  end

  it "TC-B8-2: a Kiripay payment that was never sent is sent" do
    kiripay.script(:fetch, not_found)
    kiripay.script(:authorize, not_found) # any answer; we only check it was called once
    described_class.call(payment, kiripay)
    expect(kiripay.calls[:authorize].size).to eq(1)
  end

  it "TC-B7-2: Nordpay is re-sent with the same reference" do
    nordpay = FakePspAdapter.new
    payment = create(:payment).tap(&:mark_sent!)
    nordpay.script(:fetch, PspAdapter::Result.new(status: PspAdapter::Result::Status::NotFound, psp_reference: payment.psp_reference,
                                                  psp_charge_id: nil, decline_code: nil, psp_timestamp: Time.current))
    nordpay.script(:authorize, not_found)
    described_class.call(payment, nordpay)
    expect(nordpay.calls[:authorize]).to eq([payment])
  end
end
```

**Step 2: Run, expect FAIL.** TC-B7-1 and TC-B7-4: authorize was called.

**Step 3: Implement**

```ruby
# A non-idempotent PSP's lookup may lag its writes. Wait this long after the
# first send before believing "not found" (DECISIONS #12).
LOOKUP_GRACE = T.let(30.minutes, ActiveSupport::Duration)

def self.call(payment, adapter)
  result = adapter.fetch(payment.psp_reference)
  Metrics.increment(:psp_calls, psp: adapter.name, operation: "fetch", outcome: result.status.serialize)
  return result unless result.not_found?

  # Re-sending is safe only if the PSP dedupes it (Nordpay, X-Request-Id) or
  # we never sent at all. Kiripay would take a second charge (DECISIONS #12).
  if adapter.idempotent_authorize? || payment.first_sent_at.nil?
    payment.mark_sent!
    return adapter.authorize(payment)
  end
  return nil if T.must(payment.first_sent_at) > LOOKUP_GRACE.ago

  PspAdapter::Result.new(status: PspAdapter::Result::Status::Declined, psp_reference: payment.psp_reference,
                         psp_charge_id: nil, decline_code: "psp_never_received", psp_timestamp: Time.current)
rescue PspAdapter::TimedOut => e
  # …unchanged…
end
```

**Step 4: Run the new spec, plus the authorize-job and sweeper specs.** Expected: PASS.

**Step 5: Commit** `"Never re-send an authorize to a PSP that does not deduplicate it"`.

## Task B2: the authorize job looks before it re-sends (TC-B7-3, TC-B8-1)

**Files:**
- Modify: `app/jobs/authorize_payment_job.rb` (`perform`, before `mark_sent!`)
- Test: `spec/jobs/authorize_payment_job_spec.rb`

**Step 1: Failing test**

```ruby
it "TC-B7-3 / TC-B8-1: a Kiripay retry after a send looks up instead of POSTing again" do
  kiripay = FakePspAdapter.new(name: "kiripay", currencies: %w[VND], idempotent_authorize: false)
  payment = create(:payment, :vnd).tap(&:mark_sent!) # a previous attempt sent it (5xx, or crashed)
  allow(PspRouter).to receive(:adapter).with("kiripay").and_return(kiripay)
  kiripay.script(:fetch, PspAdapter::Result.new(status: PspAdapter::Result::Status::RequiresAction,
                                                psp_reference: payment.psp_reference, psp_charge_id: "kc_1",
                                                decline_code: nil, psp_timestamp: Time.current, redirect_url: "https://k/1"))
  described_class.perform_now(payment.id)
  expect(kiripay.calls[:authorize]).to be_empty
  expect(payment.reload.state).to eq("requires_action")
end
```

**Step 2: Run, expect FAIL.** Authorize was called.

**Step 3: Implement**

```ruby
adapter = PspRouter.adapter(payment.psp_name)

# Sent before (a 5xx retry, or a crash after the call) to a PSP that does not
# dedupe: the charge may exist. Look; never POST twice (DECISIONS #12).
if payment.first_sent_at && !adapter.idempotent_authorize?
  result = ResolveUnknownPayment.call(payment, adapter)
  ApplyPspResult.call(payment, result, source: "worker") if result
  return
end
```

**Step 4: Run the full authorize-job spec.** Expected: PASS, including the old Nordpay examples.

**Step 5: Commit** `"Look up a Kiripay charge before retrying its authorize"`.

## Task B3: an abandoned customer action ends (TC-B3-1, 2, 4)

**Files:**
- Modify: `app/jobs/stuck_payment_sweeper_job.rb` (`perform`, plus a new private method)
- Test: `spec/jobs/stuck_payment_sweeper_job_spec.rb`, `spec/requests/v1/webhooks_spec.rb`

**Step 1: Failing tests**

```ruby
describe "requires_action (DECISIONS #10)" do
  let(:kiripay) { FakePspAdapter.new(name: "kiripay", currencies: %w[VND], idempotent_authorize: false) }
  let(:payment) do
    create(:payment, :vnd).tap { |p| p.transition!(:requires_action, sort_key: p.created_at + 1, source: "worker") }
  end

  before { allow(PspRouter).to receive(:adapter).with("kiripay").and_return(kiripay) }

  def kiri(status)
    PspAdapter::Result.new(status: PspAdapter::Result::Status.deserialize(status), psp_reference: payment.psp_reference,
                           psp_charge_id: "kc_1", decline_code: nil, psp_timestamp: Time.current,
                           raw: { "captured_minor" => payment.amount_minor })
  end

  it "TC-B3-1: past the timeout and still waiting → failed customer_action_expired" do
    payment.update_column(:updated_at, 31.minutes.ago)
    kiripay.script(:fetch, kiri("requires_action"))
    described_class.perform_now
    expect(payment.reload.state).to eq("failed")
    expect(payment.transitions.last.metadata).to include("decline_code" => "customer_action_expired")
    expect(OutboundEvent.where(payment:, event_type: "payment.failed").count).to eq(1)
  end

  it "TC-B3-1: past the timeout but the PSP captured it → captured and booked" do
    payment.update_column(:updated_at, 31.minutes.ago)
    kiripay.script(:fetch, kiri("captured"))
    described_class.perform_now
    expect(payment.reload.state).to eq("captured")
    expect(Ledger.captured_minor(payment)).to eq(payment.amount_minor)
  end

  it "TC-B3-2: a fresh one is left alone" do
    payment.update_column(:updated_at, 2.minutes.ago)
    described_class.perform_now
    expect(kiripay.calls[:fetch]).to be_empty
    expect(payment.reload.state).to eq("requires_action")
  end
end
```

Check where transition metadata lives (`payment_transitions.metadata`) and which association name the sweeper uses (`transitions`). Adjust to the real names.

**Step 2: Run, expect FAIL.** The state is unchanged.

**Step 3: Implement**

```ruby
# A customer who never approves in the wallet app. The PSP keeps waiting; we
# stop and say so (DECISIONS #10: abandonment is failed, not ambiguity).
REQUIRES_ACTION_TIMEOUT = T.let(30.minutes, ActiveSupport::Duration)

# in perform, beside redrive_captures
expire_customer_actions

sig { void }
def expire_customer_actions
  Payment.where(state: "requires_action").where(updated_at: ..REQUIRES_ACTION_TIMEOUT.ago)
         .order(:updated_at).limit(BATCH).each do |payment|
    result = PspRouter.adapter(payment.psp_name).fetch(payment.psp_reference)
    if [PspAdapter::Result::Status::Authorized, PspAdapter::Result::Status::Captured,
        PspAdapter::Result::Status::Declined].include?(result.status)
      ApplyPspResult.call(payment, result, source: "sweeper")
    else
      payment.transition!(:failed, sort_key: Time.current, source: "sweeper",
                                   metadata: { "decline_code" => "customer_action_expired" })
    end
  rescue PspAdapter::Unavailable, PspAdapter::TimedOut => e
    Rails.logger.warn({ event: "requires_action.check_failed", payment_id: payment.id, detail: e.message }.to_json)
  end
end
```

TC-B3-4 (a Kiripay decline webhook on `requires_action` goes to `failed`) is spec-only. Copy the signed-webhook helper from the existing `requires_action → authorized → captured` example in `webhooks_spec.rb:22-35`.

**Step 4: Run, expect PASS.** **Step 5: Commit** `"Fail wallet payments whose customer never approves"`.

## Task B4: orphan webhooks don't starve, and they stop (TC-D5-1…3)

**Files:**
- Modify: `app/jobs/stuck_payment_sweeper_job.rb` (`redrive_orphan_webhooks`)
- Test: `spec/jobs/stuck_payment_sweeper_job_spec.rb`

**Step 1: Failing tests**

```ruby
def orphan(at)
  InboundEvent.create!(psp_name: "nordpay", external_id: SecureRandom.hex(4), event_type: "charge.authorized",
                       psp_reference: "ph_missing_#{SecureRandom.hex(3)}", signature_valid: true,
                       received_at: at, payload: { "data" => {} })
end

it "TC-D5-2: old orphans don't block a new one" do
  (described_class::BATCH + 5).times { orphan(2.hours.ago) }
  fresh = orphan(2.minutes.ago)
  described_class.perform_now
  expect(ProcessInboundEventJob).to have_been_enqueued.with(fresh.id)
end

it "TC-D5-3: an orphan older than 24h is closed" do
  stale = orphan(25.hours.ago)
  described_class.perform_now
  expect(stale.reload).to have_attributes(processed_at: be_present, error: "orphan: no payment for reference")
  expect(ProcessInboundEventJob).not_to have_been_enqueued.with(stale.id)
end

it "TC-D5-1: a re-driven orphan applies once its payment exists" do
  payment = create(:payment)
  event = orphan(2.minutes.ago).tap { _1.update_columns(psp_reference: payment.psp_reference) }
  # stub parse_webhook to an authorized WebhookEvent (copy from process_inbound_event_job_spec)
  perform_enqueued_jobs { described_class.perform_now }
  expect(event.reload.processed_at).to be_present
  expect(payment.reload.state).to eq("authorized")
end
```

**Step 2: Run, expect FAIL.**

**Step 3: Implement**

```ruby
# Orphans: a webhook for a payment row not yet written. Keep trying for a day,
# half oldest and half newest so a backlog can't starve fresh ones (#13).
# After a day the charge isn't ours: close it loudly.
ORPHAN_WINDOW = T.let(24.hours, ActiveSupport::Duration)

sig { void }
def redrive_orphan_webhooks
  waiting = InboundEvent.unprocessed.where(signature_valid: true)
  waiting.where(received_at: ...ORPHAN_WINDOW.ago).limit(BATCH).each do |event|
    event.update!(processed_at: Time.current, error: "orphan: no payment for reference")
    Metrics.increment(:webhook_orphans_abandoned, psp: event.psp_name)
    Rails.logger.error({ event: "webhook.orphan_abandoned", inbound_event_id: event.id,
                         psp_reference: event.psp_reference }.to_json)
  end

  live = waiting.where(received_at: ORPHAN_WINDOW.ago..1.minute.ago)
  half = BATCH / 2
  ids = live.order(:received_at).limit(half).pluck(:id) | live.order(received_at: :desc).limit(half).pluck(:id)
  ids.each { |id| ProcessInboundEventJob.perform_later(id) }
end
```

**Step 4: Run, expect PASS.** **Step 5: Commit** `"Keep orphan webhooks from starving, and close them after a day"`.

## Task B5: the sweeper vs webhook race, and DECISIONS #7 (TC-C4-1)

**Files:**
- Test: `spec/jobs/stuck_payment_sweeper_job_spec.rb` (tagged `:concurrency`)
- Modify: `DECISIONS.md` #7, and `app/jobs/stuck_payment_sweeper_job.rb` (remove the dead `StaleObjectError` rescue)

**Step 1: Spec.** Two threads with a `Concurrent::CyclicBarrier`, following the pattern in `spec/services/create_refund_spec.rb`:
- Thread 1: `ResolveUnknownPayment` plus `ApplyPspResult` returning authorized.
- Thread 2: `ProcessInboundEventJob` with an authorized event.
- Assert: `payment.transitions.where(to_state: "authorized").count == 1`, one `payment.authorized` event, and no exception from either thread.

**Step 2:** Run it 20 times:

```bash
for i in $(seq 20); do TEST_DATABASE=… bundle exec rspec … -e TC-C4-1 || break; done
```

Expected: PASS. This is a characterisation test; the code is already safe.

**Step 3:**
- Rewrite DECISIONS #7. The title becomes "Concurrent writers serialize on a row lock; 'already there' is success". The body explains `with_lock` (FOR UPDATE) and the tolerance in `apply_psp_result.rb:75-81`. Keep the history: `lock_version` was the first design.
- Remove the unreachable rescue if the spec stays green without it.

**Step 4: Commit** `"Prove the sweeper/webhook race is safe and describe the real locking"`.

## Task B6: docs

- **DECISIONS #12:** the rule is now enforced. Describe the 30-minute lookup grace and the trade-off: a request that never reached Kiripay fails rather than being re-sent.
- **DECISIONS #13:** orphan handling.
- **README state notes:** `requires_action` times out after 30 min.

**Commit** `"Document Kiripay re-send rule, orphan window and wallet timeout"`.

---

# Lane C: platform, books, audit

## Task C1: only active, un-rolled keys can be rolled (TC-L3-1…3)

**Files:**
- Modify: `app/models/api_key.rb` (add `rollable?`)
- Modify: `app/controllers/dashboard/api/api_keys_controller.rb:30-40`
- Test: `spec/requests/dashboard/api/api_keys_spec.rb`

**Step 1: Failing tests.** Reuse the signed-in and stepped-up admin setup at the top of this spec.

```ruby
it "TC-L3-1: rolling an expired key is refused and leaves it dead" do
  key.update_column(:expires_at, 1.hour.ago)
  post "/dashboard/api/api_keys/#{key.id}/roll", params: { expires_in: "24h" }.to_json, headers: json_headers
  expect(response).to have_http_status(:conflict)
  expect(json_body["error"]["code"]).to eq("invalid_state")
  expect(key.reload.expires_at).to be < Time.current
  expect(ApiKey.count).to eq(keys_before)
end

it "TC-L3-2: rolling a revoked key is refused" do
  key.revoke!
  # same request; expect 409 invalid_state
end

it "TC-L3-3: a key already rolled can't be rolled again" do
  post "/dashboard/api/api_keys/#{key.id}/roll", params: { expires_in: "24h" }.to_json, headers: json_headers
  post "/dashboard/api/api_keys/#{key.id}/roll", params: { expires_in: "24h" }.to_json, headers: json_headers
  expect(response).to have_http_status(:conflict)
end
```

**Step 2: Run, expect FAIL.** It returns 201.

**Step 3: Implement**

```ruby
# api_key.rb
# Live, and not already on its way out from an earlier roll. Rolling an
# expired key would set a fresh expires_at and bring it back (USE_CASES bug 5).
sig { returns(T::Boolean) }
def rollable? = revoked_at.nil? && expires_at.nil?

# api_keys_controller.rb#roll, after find
unless key.rollable?
  raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "invalid_state",
                     message: "Only an active key that has not been rolled can be rolled; roll its replacement")
end
```

Check that `ApiKey.issue!` never sets `expires_at`. If it can, use `expires_at.nil? || (expires_at > Time.current && !rolled?)` with a `rolled_at` column instead.

**Step 4: Run, expect PASS.** **Step 5: Commit** `"Refuse to roll an expired, revoked or already-rolled key"`.

## Task C2: a redelivered event gets a new budget (TC-H4-1, 2)

**Files:**
- Create: `db/migrate/20261020000002_add_attempt_budget_to_outbound_events.rb`
- Modify: `app/models/outbound_event.rb:49-53`, `app/jobs/deliver_outbound_events_job.rb:67`
- Test: `spec/jobs/deliver_outbound_events_job_spec.rb`

**Step 1: Failing test**

```ruby
it "TC-H4-1: a redelivered dead event gets 8 more attempts, numbered on" do
  event = create_dead_event(attempts: 8) # build with OutboundEvent.emit! + update_columns(state: "dead", attempts: 8)
  event.redeliver!
  stub_request(:post, merchant.webhook_url).to_return(status: 503)
  7.times { event.update_column(:next_attempt_at, Time.current); described_class.perform_now }
  expect(event.reload).to have_attributes(state: "pending", attempts: 15)
  event.update_column(:next_attempt_at, Time.current)
  described_class.perform_now
  expect(event.reload).to have_attributes(state: "dead", attempts: 16)
  expect(event.delivery_attempts.pluck(:attempt_number).last(8)).to eq((9..16).to_a)
end
```

**Step 2: Run, expect FAIL.** The event is dead at attempt 9.

**Step 3: Implement**

```ruby
# migration
add_column :outbound_events, :attempt_budget, :integer, null: false, default: 8

# outbound_event.rb#redeliver!
# A resend is a fresh delivery with its own retries (Stripe); attempt numbers
# keep counting so delivery history stays unique per event.
update!(state: "pending", next_attempt_at: Time.current, last_error: nil, attempt_budget: attempts + MAX_ATTEMPTS)

# deliver_outbound_events_job.rb:67
elsif attempt_number >= event.attempt_budget
```

**Step 4: Migrate, run, expect PASS.** **Step 5: Commit** `"Give a redelivered webhook a full retry budget"`.

## Task C3: payment history is append-only in Postgres (TC-I2-1…4)

**Files:**
- Create: `db/migrate/20261020000003_make_payment_transitions_append_only.rb`
- Create: `spec/models/payment_transition_spec.rb`
- Test also: `spec/services/ledger_spec.rb` (TC-I2-4)

**Step 1: Failing tests**

```ruby
require "rails_helper"

RSpec.describe PaymentTransition do
  let(:payment) { create(:payment).tap { |p| p.transition!(:authorized, sort_key: p.created_at + 1, source: "worker") } }
  let(:row) { payment.transitions.order(:sort_key).first }
  let(:db) { ActiveRecord::Base.connection }

  it "TC-I2-1: the database refuses an UPDATE" do
    expect { db.execute("UPDATE payment_transitions SET to_state = 'failed' WHERE id = '#{row.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "TC-I2-2: the database refuses DELETE and TRUNCATE" do
    expect { db.execute("DELETE FROM payment_transitions WHERE id = '#{row.id}'") }.to raise_error(ActiveRecord::StatementInvalid)
    expect { db.execute("TRUNCATE payment_transitions CASCADE") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "TC-I2-3: the most_recent true→false flip is the one change allowed" do
    expect { payment.transition!(:captured, sort_key: payment.created_at + 2, source: "worker") }.not_to raise_error
    old = payment.transitions.where(most_recent: false).first
    expect { db.execute("UPDATE payment_transitions SET most_recent = true WHERE id = '#{old.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
  end
end

# ledger_spec.rb
it "TC-I2-4: ledger_entries refuses TRUNCATE" do
  expect { ActiveRecord::Base.connection.execute("TRUNCATE ledger_entries CASCADE") }
    .to raise_error(ActiveRecord::StatementInvalid)
end
```

**Step 2: Run, expect FAIL.** The statements succeed.

**Step 3: Migration.** First check the `transition!` flip in `payment.rb:95`: does it also set `updated_at`? The JSON comparison below ignores `updated_at` in case it does.

```ruby
class MakePaymentTransitionsAppendOnly < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE FUNCTION payment_transitions_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        -- The one write history allows: the previous step stops being current.
        IF TG_OP = 'UPDATE' AND OLD.most_recent AND NOT NEW.most_recent
           AND (to_jsonb(OLD) - 'most_recent' - 'updated_at') = (to_jsonb(NEW) - 'most_recent' - 'updated_at') THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'payment_transitions is append-only (%)', TG_OP;
      END $$;
      CREATE TRIGGER trg_payment_transitions_append_only BEFORE UPDATE OR DELETE ON payment_transitions
        FOR EACH ROW EXECUTE FUNCTION payment_transitions_append_only();
      CREATE TRIGGER trg_payment_transitions_no_truncate BEFORE TRUNCATE ON payment_transitions
        FOR EACH STATEMENT EXECUTE FUNCTION append_only_guard();
      CREATE TRIGGER trg_ledger_entries_no_truncate BEFORE TRUNCATE ON ledger_entries
        FOR EACH STATEMENT EXECUTE FUNCTION append_only_guard();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER trg_ledger_entries_no_truncate ON ledger_entries;
      DROP TRIGGER trg_payment_transitions_no_truncate ON payment_transitions;
      DROP TRIGGER trg_payment_transitions_append_only ON payment_transitions;
      DROP FUNCTION payment_transitions_append_only();
    SQL
  end
end
```

**Step 4: Migrate, run the new spec, then the FULL suite.**
- The `:concurrency` cleanup uses `session_replication_role = replica`, which skips these triggers.
- Check that `bin/rails db:seed` and the demo reset still run. The demo never deletes (DOMAIN.md).

**Step 5: Commit** `"Make payment history append-only in the database"`.

## Task C4: settlement mismatches are flagged, never lost (TC-J3-1…3, TC-J4-1, TC-J1-2)

**Files:**
- Modify: `app/jobs/settlement_reconciliation_job.rb` (`ingest`, `match`, `refund_problem`)
- Test: `spec/jobs/settlement_reconciliation_job_spec.rb`

**Step 1: Failing tests.** Reuse the `line(...)` builder already in this spec:

```ruby
it "TC-J3-1: net ≠ gross − fee is a mismatch, and the next line still books" do
  bad = line(kind: "capture", gross_minor: 2500, fee_minor: 45, net_minor: 2400)
  good = line(kind: "capture", psp_reference: other.psp_reference, gross_minor: 2500, fee_minor: 45, net_minor: 2455)
  adapter.script(:settlement_report, [bad, good])
  expect { described_class.perform_now(day) }.not_to raise_error
  expect(SettlementLine.find_by(external_id: bad.external_id)).to have_attributes(status: "mismatch", problem: /net 2400/)
  expect(SettlementLine.find_by(external_id: good.external_id).status).to eq("matched")
end

it "TC-J4-1: a second line for a refund already settled is a mismatch, not a duplicate" do
  # L1 and L2 have different external ids and the same refund_reference
  expect(SettlementLine.find_by(external_id: l2.external_id)).to have_attributes(status: "mismatch", problem: /already settled/)
end

it "TC-J1-2: two capture lines for one multicaptured payment both match" do
  # payment captured 1000 + 1500; lines gross 1000 and 1500
  expect(SettlementLine.where(psp_reference: payment.psp_reference).pluck(:status)).to eq(%w[matched matched])
end
```

Write TC-J3-2 (currency) and TC-J3-3 (refund amount) the same way. Both are already handled, so they are spec-only.

**Step 2: Run, expect FAIL.** J3-1 raises `Ledger::Unbalanced`, and J4-1 is reported as a duplicate with no row.

**Step 3: Implement**

```ruby
def ingest(psp_name, day, report_line)
  return "duplicate" if SettlementLine.exists?(psp_name: psp_name, external_id: report_line.external_id)
  # …existing transaction…
rescue ActiveRecord::RecordNotUnique
  "duplicate" # a concurrent run ingested the same line id
end

def match(psp_name, line)
  # …payment + currency checks unchanged…
  if line.net_minor != line.gross_minor - line.fee_minor
    return discrepancy!(line, "mismatch", "net #{line.net_minor} ≠ gross #{line.gross_minor} − fee #{line.fee_minor}", payment:)
  end
  problem = …
  return discrepancy!(line, "mismatch", problem, payment:) if problem

  Ledger.record_settlement!(line.tap { _1.payment = payment })
  line.update!(payment: payment, status: "matched")
end

# refund_problem, after the refund lookup
if SettlementLine.where(refund: refund, status: "matched").where.not(id: line.id).exists?
  return "refund already settled by another line"
end
```

**Step 4: Run the full settlement spec, expect PASS.** **Step 5: Commit** `"Flag settlement lines that cannot balance or settle a refund twice"`.

## Task C5: refusals are audited (TC-M14-1…3, TC-N17-1)

**Files:**
- Modify: `app/controllers/web/base_controller.rb:19,36` (`render_api_error`, shared by the dashboard and ops)
- Test: `spec/requests/dashboard/api/payments_spec.rb`, `spec/requests/ops/api/proposals_spec.rb`

**Step 1: Failing tests**

```ruby
it "TC-M14-1: a refused refund is audited without the request body" do
  post "/dashboard/api/payments/#{payment.id}/refunds", params: { amount_minor: 999_999, reason: "x" }.to_json,
                                                         headers: json_headers
  expect(response).to have_http_status(:unprocessable_content)
  row = AuditEvent.order(:created_at).last
  expect(row).to have_attributes(result: "failure", action: "dashboard/api/refunds#create")
  expect(row.metadata).to include("code" => "validation_error", "http_status" => 422)
  expect(row.metadata.to_s).not_to include("999999")
end

it "TC-M14-2: GET 404s and anonymous 401s write nothing" do
  expect { get "/dashboard/api/payments/nope" }.not_to change(AuditEvent, :count)
end

it "TC-N17-1: self-approval is audited as a failure" do
  post "/ops/api/proposals/#{own.id}/approve", headers: ops_headers
  expect(AuditEvent.order(:created_at).last).to have_attributes(result: "failure")
end
```

**Step 2: Run, expect FAIL.** No row is written.

**Step 3: Implement**

```ruby
# web/base_controller.rb
def render_api_error(error)
  audit_refusal(error)
  # …existing render…
end

# A mutating request refused for a business rule is evidence too (PCI 10.2).
# Not: reads, anonymous 401s (would fill an append-only table), and 403s,
# which Authorization#record_denial already wrote.
sig { params(error: ApiError).void }
def audit_refusal(error)
  return if request.get? || request.head?
  return if error.http_status == 403
  return if error.http_status == 401 && error.code != "step_up_required"
  return unless respond_to?(:audit!, true) && signed_in_principal?

  audit!("#{controller_path}##{action_name}", result: error.code == "step_up_required" ? "denied" : "failure",
                                              metadata: { "code" => error.code, "http_status" => error.http_status })
rescue StandardError => e
  # Never let auditing hide the error the caller must see.
  Rails.logger.error({ event: "audit_refusal_failed", detail: e.message }.to_json)
end
```

`signed_in_principal?` is `@current_user.present?`. Define it in the dashboard and ops base controllers, and return false in any other `Web::BaseController` subclass.

**Step 4: Run both specs, then the full suite.** Check that existing specs asserting `AuditEvent.count` still hold; update them only where they now correctly see a refusal row.

**Step 5: Commit** `"Audit refused dashboard and ops actions"`.

## Task C6: a proposal token reused by another operator returns 409 (TC-N7-1, 2)

**Files:**
- Modify: `app/controllers/ops/api/proposals_controller.rb:23-39`
- Test: `spec/requests/ops/api/proposals_spec.rb`

**Step 1: Failing test**

```ruby
it "TC-N7-1: another operator's client_token is 409, not 500" do
  create(:operator_proposal, client_token: "tok-1", proposed_by: other_operator)
  post "/ops/api/proposals", params: proposal_params.merge(client_token: "tok-1").to_json, headers: ops_headers
  expect(response).to have_http_status(:conflict)
  expect(json_body["error"]["code"]).to eq("client_token_in_use")
end
```

**Step 2: Run, expect FAIL** (500, `RecordNotUnique`).

**Step 3: Implement**

```ruby
def create
  token = params.require(:client_token)
  if (existing = OperatorProposal.find_by(client_token: token))
    return render(json: ProposalSerializer.call(existing, viewer: current_user)) if existing.proposed_by_id == current_user.id

    raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "client_token_in_use",
                       message: "That client_token belongs to another proposal")
  end
  proposal = OperatorProposal.create!(…unchanged…)
  # …
rescue ActiveRecord::RecordNotUnique
  retry # a concurrent submit won; the lookup above now finds it (DECISIONS #26)
end
```

The single `retry` is safe: the second pass always finds the row.

**Step 4: Run `-e TC-N7`.** TC-N7-2 uses two threads under `:concurrency`. **Step 5: Commit** `"Answer a reused proposal token with 409"`.

## Task C7: refuse a card number sent as a token (TC-A14-1, 2)

**Files:**
- Create: `app/lib/card_number.rb`, `spec/lib/card_number_spec.rb`
- Modify: `app/controllers/v1/payments_controller.rb:89`
- Modify: `spec/requests/v1/pan_never_logged_spec.rb` (it expects 202 today)

**Step 1: Failing tests**

```ruby
RSpec.describe CardNumber do
  it "TC-A14-1: recognises Luhn-valid 13–19 digit numbers, with spaces or dashes" do
    expect(described_class.looks_like_pan?("4242 4242 4242 4242")).to be(true)
    expect(described_class.looks_like_pan?("4242-4242-4242-4242")).to be(true)
  end

  it "TC-A14-2: leaves real tokens and non-Luhn numbers alone" do
    %w[tok_visa wallet_abc123 4242424242424241].each { expect(described_class.looks_like_pan?(_1)).to be(false) }
  end
end
```

In `pan_never_logged_spec.rb`, change the 202 expectation to:

```ruby
expect(response).to have_http_status(:unprocessable_content)
expect(json_body["error"]["details"]).to have_key("payment_method_token")
expect(response.body).not_to include("4242424242424242")
expect(Payment.count).to eq(0)
```

Keep every existing log and table assertion.

**Step 2: Run, expect FAIL** (NameError, then 202).

**Step 3: Implement**

```ruby
# typed: strict
# frozen_string_literal: true

# A PAN must never reach our tables (PCI DSS 3.3). A merchant that sends one
# in place of a token gets a 422, and the number is never echoed back.
module CardNumber
  extend T::Sig

  sig { params(value: T.untyped).returns(T::Boolean) }
  def self.looks_like_pan?(value)
    digits = value.to_s.gsub(/[\s-]/, "")
    return false unless digits.match?(/\A\d{13,19}\z/)

    sum = digits.reverse.each_char.with_index.sum do |char, index|
      d = char.to_i
      next d if index.even?

      d *= 2
      d > 9 ? d - 9 : d
    end
    (sum % 10).zero?
  end
end

# payments_controller.rb, after the presence check
if CardNumber.looks_like_pan?(body["payment_method_token"])
  errors["payment_method_token"] << "looks like a card number; send a token from your card vault"
end
```

**Step 4: Run both specs and the request specs.** **Step 5: Commit** `"Refuse card numbers sent as payment tokens"`.

## Task C8: docs

- **DOMAIN.md:** add payment history to the database-enforced "written in pen" list.
- **RUNBOOK:** redeliver gives 8 more attempts.
- **README:** API errors `client_token_in_use`, and `payment_method_token` refusal.

**Commit** `"Document append-only history, redelivery budget and token refusal"`.

---

# Merge and verify

## Task M1: merge the lanes

```bash
git checkout fix/use-case-coverage
git merge --no-ff <lane-a-branch>
git merge --no-ff <lane-b-branch>   # conflict expected: adapter capability hunks — keep all three flags once
git merge --no-ff <lane-c-branch>   # conflict expected: db/structure.sql
```

For the `db/structure.sql` conflict, take either side, then regenerate it from all the migrations:

```bash
TEST_DATABASE=payhub_test_merge RAILS_ENV=test bin/rails db:drop db:create db:schema:load db:migrate
git add db/structure.sql && git commit
```

## Task M2: full verification

```bash
TEST_DATABASE=payhub_test_merge bundle exec rspec          # expect ≥ 722 + new, 0 failures
bundle exec srb tc                                          # expect No errors
bin/check 2>/dev/null || bundle exec rubocop                # expect no new offenses
npx vitest run                                              # front-end unit tests
for s in $(seq 1 20); do SEED=$s TEST_DATABASE=payhub_test_merge bundle exec rspec spec/simulation; done
bundle exec rspec $(grep -rl "TC-" spec) -e "TC-"          # every TC example listed
```

Cross-check every TC id in TEST_CASES §1–§2 against `grep -rho "TC-[A-Z0-9]*-[0-9]*" spec | sort -u`. Any id without a spec is a gap to report.

## Task M3: independent review

Dispatch a `code-reviewer` agent over `git diff master...fix/use-case-coverage`, with this brief:
- money invariants (ledger nets to zero, captured ≤ authorized, refunded + reserved ≤ captured)
- no new path that re-POSTs to Kiripay
- the triggers don't break migrations, seeds or the demo reset
- audit rows never contain request bodies

Fix what it confirms, then re-run M2.

Then update the TEST_CASES.md "Now" markers to ✅, and the USE_CASES.md §1 statuses.

---

# Phase 2: test gaps (TEST_CASES §3)

Specs only. Each item follows the same five steps:
1. Write the TC example.
2. Run it. Expect PASS, because the behaviour already works. If it FAILS, stop: it is a new bug, so record it in USE_CASES §1.
3. Commit.

Split the work by spec directory so agents don't collide:

| Agent | Directory | TCs |
| --- | --- | --- |
| P1 | `spec/requests/v1/` | A1-2, A2-1, A4-1, A5-1, A7-1, A11-1, A12-1, E9-1, E5-1, E10-1, F7-1, G1-2, D1-1, D2-1, D7-1, H3-1, G7-1 |
| P2 | `spec/jobs/`, `spec/models/`, `spec/adapters/` | B6-1, B9-1, C8-1, E6-1, E8-1, F1-1, F10-1, E1-2, G4-1, I1-1, J7-1, L1-1 |
| P3 | `spec/requests/dashboard/`, `spec/requests/ops/`, `spec/routing/`, `spec/lib/` | M6-1, M9-1 (new fixture `spec/fixtures/route_permissions.yml`), N8-1, N9-1, N10-1, O1-1, H6-1 |
