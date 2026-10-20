require "rails_helper"

RSpec.describe StuckPaymentSweeperJob do
  let(:adapter) { FakePspAdapter.new }

  before { allow(PspRouter).to receive(:adapter).and_return(adapter) }

  def result(payment, status, **overrides)
    -> { PspAdapter::Result.new({ status: PspAdapter::Result::Status.deserialize(status.to_s), psp_reference: payment.psp_reference,
                                  psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: adapter.received_at(:fetch) + 0.001 }.merge(overrides)) }
  end

  # `unknown` is dated a millisecond after creation (as sent_at would be), so a
  # PSP verdict fetched later is newer and applies rather than being stale.
  def stuck(state, age:)
    create(:payment).tap do |p|
      p.transition!(:unknown, sort_key: p.created_at + 0.001, source: "worker") if state == "unknown"
      p.update_column(:updated_at, age.ago)
    end
  end

  it "resolves an `unknown` payment by polling — never by re-sending the authorize" do
    payment = stuck("unknown", age: 5.minutes)
    adapter.script(:fetch, result(payment, :authorized))

    described_class.perform_now

    expect(payment.reload.state).to eq("authorized")
    expect(adapter.calls[:authorize]).to be_empty
    expect(payment.transitions.find_by(most_recent: true).source).to eq("sweeper")
  end

  it "re-sends with the SAME reference only when the PSP has never seen it (404)" do
    payment = stuck("pending", age: 5.minutes)
    adapter.script(:fetch, result(payment, :not_found))
    adapter.script(:authorize, result(payment, :authorized))

    described_class.perform_now

    expect(adapter.calls[:authorize].map(&:psp_reference)).to eq([payment.psp_reference])
    expect(payment.reload.state).to eq("authorized")
  end

  context "with a PSP that does not deduplicate authorizes (Kiripay, DECISIONS #12)" do
    let(:adapter) { FakePspAdapter.new(name: "kiripay", currencies: %w[VND], idempotent_authorize: false) }

    def stuck_vnd(age:)
      create(:payment, :vnd).tap { |p| p.update_column(:updated_at, age.ago) }
    end

    it "TC-B8-2: sends the first POST for a payment the worker never sent" do
      payment = stuck_vnd(age: 5.minutes)
      adapter.script(:fetch, result(payment, :not_found))
      adapter.script(:authorize, result(payment, :requires_action))

      described_class.perform_now

      expect(adapter.calls[:authorize].map(&:psp_reference)).to eq([payment.psp_reference])
      expect(payment.reload.state).to eq("requires_action")
    end

    it "never re-sends one that was sent: it waits, then fails it as never received" do
      payment = stuck_vnd(age: 5.minutes)
      travel_to(5.minutes.ago, with_usec: true) { payment.mark_sent! }
      adapter.script(:fetch, result(payment, :not_found))

      described_class.perform_now
      expect(payment.reload.state).to eq("pending")

      travel ResolveUnknownPayment::LOOKUP_GRACE do
        adapter.script(:fetch, result(payment, :not_found, psp_timestamp: Time.current))
        described_class.perform_now
      end

      expect(adapter.calls[:authorize]).to be_empty
      expect(payment.reload.state).to eq("failed")
      expect(payment.transitions.find_by(most_recent: true).metadata).to include("decline_code" => "psp_never_received")
    end
  end

  describe "abandoned customer actions (requires_action)" do
    let(:adapter) { FakePspAdapter.new(name: "kiripay", currencies: %w[VND], idempotent_authorize: false) }

    # A Kiripay payment that returned a redirect `age` ago; the customer has
    # not come back.
    def waiting_on_customer(age:)
      create(:payment, :vnd).tap do |p|
        p.mark_sent!(p.created_at)
        p.transition!(:requires_action, sort_key: p.created_at + 0.001, source: "worker")
        p.update_column(:updated_at, age.ago)
      end
    end

    let(:timeout) { described_class::REQUIRES_ACTION_TIMEOUT }

    it "TC-B3-1: the PSP says captured — books the full amount and moves to captured, as the webhook would" do
      payment = waiting_on_customer(age: timeout + 1.minute)
      adapter.script(:fetch, result(payment, :captured))

      described_class.perform_now

      expect(payment.reload.state).to eq("captured")
      expect(Ledger.captured_minor(payment)).to eq(payment.amount_minor)
      expect(adapter.calls[:authorize]).to be_empty
    end

    it "TC-B3-1: the PSP says declined — failed" do
      payment = waiting_on_customer(age: timeout + 1.minute)
      adapter.script(:fetch, result(payment, :declined, decline_code: "wallet_declined"))

      described_class.perform_now

      expect(payment.reload.state).to eq("failed")
      expect(payment.transitions.find_by(most_recent: true).metadata).to include("decline_code" => "wallet_declined")
    end

    it "TC-B3-1: the PSP still waits on the customer — failed as customer_action_expired, with payment.failed" do
      payment = waiting_on_customer(age: timeout + 1.minute)
      adapter.script(:fetch, result(payment, :requires_action))

      described_class.perform_now

      expect(payment.reload.state).to eq("failed")
      expect(payment.transitions.find_by(most_recent: true).metadata)
        .to include("decline_code" => "customer_action_expired")
      expect(OutboundEvent.where(payment: payment, event_type: "payment.failed").count).to eq(1)
      expect(adapter.calls[:authorize]).to be_empty
    end

    it "TC-B3-2: leaves a fresh requires_action payment alone — no PSP call, no state change" do
      payment = waiting_on_customer(age: 2.minutes)

      described_class.perform_now

      expect(adapter.calls[:fetch]).to be_empty
      expect(payment.reload.state).to eq("requires_action")
    end

    it "does not expire one an operator polls before the timeout" do
      payment = waiting_on_customer(age: 2.minutes)
      adapter.script(:fetch, result(payment, :requires_action))

      described_class.poll_now(payment)

      expect(payment.reload.state).to eq("requires_action")
    end

    it "pushes the next check out when the PSP cannot be reached, so the next sweep does not repeat it" do
      payment = waiting_on_customer(age: timeout + 1.minute)
      adapter.script(:fetch, PspAdapter::Unavailable)

      described_class.perform_now
      expect { described_class.perform_now }.not_to raise_error # not due again yet: no scripted answer consumed

      expect(payment.reload.state).to eq("requires_action")
      expect(payment.next_check_at).to be > Time.current
    end
  end

  it "leaves fresh payments alone and resolves only those past the threshold" do
    fresh = stuck("unknown", age: 30.seconds)
    old = stuck("unknown", age: 5.minutes)
    adapter.script(:fetch, result(old, :declined))

    described_class.perform_now

    expect(fresh.reload.state).to eq("unknown")
    expect(old.reload.state).to eq("failed")
    expect(adapter.calls[:fetch]).to eq([old.psp_reference])
  end

  it "keeps going when one PSP call fails — a single bad payment must not stop the batch" do
    a = stuck("unknown", age: 5.minutes)
    b = stuck("unknown", age: 4.minutes)
    adapter.script(:fetch, PspAdapter::Unavailable, result(b, :authorized))

    expect { described_class.perform_now }.not_to raise_error
    expect(a.reload.state).to eq("unknown")
    expect(b.reload.state).to eq("authorized")
  end

  it "fires the 15-minute alert (ERROR log + counter) and sets the unknown gauge" do
    stuck("unknown", age: 20.minutes)
    stuck("unknown", age: 3.minutes)
    adapter.script(:fetch, PspAdapter::TimedOut, PspAdapter::TimedOut) # PSP still down; nothing resolves
    allow(Rails.logger).to receive(:error).and_call_original
    allow(Metrics).to receive(:increment).and_call_original
    allow(Metrics).to receive(:gauge).and_call_original

    described_class.perform_now

    expect(Rails.logger).to have_received(:error).with(a_string_including('"event":"alert.stuck_payment"')).once
    expect(Metrics).to have_received(:increment).with(:stuck_payment_alerts, psp: "nordpay", state: "unknown").once
    expect(Metrics).to have_received(:gauge).with(:unknown_state_payments, 2)
  end

  describe "scheduling (DECISIONS #13)" do
    it "polls a newly stuck payment even when a backlog of unresolvable ones fills the batch" do
      # The regression the chaos run found: order(:updated_at).limit(BATCH)
      # re-picked the same oldest rows forever, so a new `unknown` was never polled.
      stub_const("#{described_class}::BATCH", 4)
      backlog = Array.new(6) { |i| stuck("unknown", age: (60 - i).days) }
      fresh = stuck("unknown", age: 3.minutes)
      allow(adapter).to receive(:fetch) do |ref|
        raise PspAdapter::Unavailable, "gone" unless ref == fresh.psp_reference

        PspAdapter::Result.new(status: PspAdapter::Result::Status::Authorized, psp_reference: ref,
                               psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: Time.current)
      end

      described_class.perform_now

      expect(fresh.reload.state).to eq("authorized")
      expect(adapter).to have_received(:fetch).exactly(4).times
      # the other half of the batch went to the most overdue of the backlog
      expect(adapter).to have_received(:fetch).with(backlog.first.psp_reference)
    end

    it "pushes a failed poll's next check out by its backoff, so the next sweep does not repeat it" do
      payment = stuck("unknown", age: 5.minutes)
      adapter.script(:fetch, PspAdapter::Unavailable)

      described_class.perform_now
      payment.reload
      expect(payment.check_attempts).to eq(1)
      expect(payment.next_check_at).to be_within(15.seconds).of(1.minute.from_now)

      expect { described_class.perform_now }.not_to raise_error # nothing due: no scripted answer consumed
      expect(adapter.calls[:fetch].size).to eq(1)

      travel 2.minutes do
        adapter.script(:fetch, result(payment, :authorized))
        described_class.perform_now
      end
      expect(payment.reload.state).to eq("authorized")
    end

    it "starts the backoff over when the payment changes state" do
      payment = create(:payment)
      payment.update_columns(check_attempts: 7, next_check_at: 1.hour.from_now)

      payment.transition!(:unknown, sort_key: payment.created_at + 0.001, source: "worker")

      expect(payment.reload).to have_attributes(check_attempts: 0, next_check_at: nil)
    end

    it "lets an operator poll one payment now, whatever its backoff (RUNBOOK §4)" do
      payment = stuck("unknown", age: 5.minutes)
      payment.update_columns(next_check_at: 20.minutes.from_now, check_attempts: 5)
      adapter.script(:fetch, result(payment, :authorized))

      described_class.poll_now(payment)

      expect(payment.reload.state).to eq("authorized")
    end

    it "backs off exponentially with jitter and caps at 30 minutes" do
      delays = (0..12).map { |n| described_class.check_delay(n) }
      expect(delays.first).to be_between(48, 72)
      expect(delays[4]).to be_between(16 * 60 * 0.8, 16 * 60 * 1.2)
      expect(delays.last(6)).to all(be_between(30 * 60 * 0.8, 30 * 60 * 1.2))
    end
  end

  describe "orphan webhooks (DECISIONS #13)" do
    def orphan(received_at:, reference: "ph_#{SecureRandom.hex(6)}", payload: { "id" => "x" })
      InboundEvent.create!(psp_name: "kiripay", external_id: "evt_#{SecureRandom.hex(6)}", event_type: "charge.captured",
                           psp_reference: reference, payload: payload, signature_valid: true, received_at: received_at)
    end

    it "TC-D5-1: an orphan is applied once its payment exists" do
      allow(PspRouter).to receive(:adapter).with("kiripay").and_return(KiripayAdapter.new)
      at = 3.minutes.ago
      payload = { "id" => "evt_early", "type" => "charge.captured", "created_at" => at.utc.iso8601(3),
                  "data" => { "id" => "kp_1", "merchant_reference" => "ph_early", "status" => "captured",
                              "amount" => "500000", "currency" => "VND", "created_at" => at.utc.iso8601(3) } }
      event = orphan(received_at: at, reference: "ph_early", payload: payload)
      ProcessInboundEventJob.perform_now(event.id) # arrives before the payment row: left unprocessed
      expect(event.reload.processed_at).to be_nil

      # The row our worker wrote (dated before the PSP's event), not yet due a poll of its own.
      payment = travel_to(at - 1.second) { create(:payment, :vnd, psp_reference: "ph_early") }
      payment.update_columns(next_check_at: 1.hour.from_now)
      perform_enqueued_jobs(only: ProcessInboundEventJob) { described_class.perform_now }

      expect(event.reload.processed_at).to be_present
      expect(payment.reload.state).to eq("captured")
      expect(Ledger.captured_minor(payment)).to eq(500_000)
    end

    it "TC-D5-2: old orphans do not block a new one" do
      stub_const("#{described_class}::BATCH", 4)
      Array.new(4 + 5) { |i| orphan(received_at: (20 - i).hours.ago) } # a backlog that fills the batch
      fresh = orphan(received_at: 2.minutes.ago)

      expect { described_class.perform_now }.to have_enqueued_job(ProcessInboundEventJob).with(fresh.id)
    end

    it "TC-D5-3: an orphan older than 24h is closed with an error and an ERROR log, and not re-driven again" do
      old = orphan(received_at: 25.hours.ago)
      allow(Rails.logger).to receive(:error).and_call_original
      allow(Metrics).to receive(:increment).and_call_original

      expect { described_class.perform_now }.not_to have_enqueued_job(ProcessInboundEventJob)

      expect(old.reload).to have_attributes(processed_at: be_present, error: "orphan: no payment for reference")
      expect(Rails.logger).to have_received(:error).with(a_string_including('"event":"webhook.orphan_abandoned"'))
      expect(Metrics).to have_received(:increment).with(:orphan_webhooks_abandoned, psp: "kiripay")
      expect { described_class.perform_now }.not_to have_enqueued_job(ProcessInboundEventJob)
    end

    it "does not close an old unprocessed event whose payment exists: that is a processing failure, not an orphan" do
      payment = create(:payment, :vnd)
      payment.update_columns(next_check_at: 1.hour.from_now)
      event = orphan(received_at: 25.hours.ago, reference: payment.psp_reference)

      described_class.perform_now

      expect(event.reload.processed_at).to be_nil
    end
  end

  it "re-drives pending refunds and orphan webhooks, and expires idempotency keys" do
    payment = create(:payment)
    refund = create(:refund, payment: payment)
    refund.update_column(:updated_at, 5.minutes.ago)
    orphan = InboundEvent.create!(psp_name: "nordpay", external_id: "evt_o", event_type: "charge.captured",
                                  psp_reference: "ph_unknown", payload: { "id" => "evt_o" }, signature_valid: true,
                                  received_at: 2.minutes.ago)
    IdempotencyKey.create!(merchant: payment.merchant, key: "old", request_fingerprint: "x", expires_at: 1.hour.ago)
    IdempotencyKey.create!(merchant: payment.merchant, key: "live", request_fingerprint: "x", expires_at: 1.hour.from_now)

    expect { described_class.perform_now }
      .to have_enqueued_job(RefundPaymentJob).with(refund.id)
      .and have_enqueued_job(ProcessInboundEventJob).with(orphan.id)
    expect(IdempotencyKey.pluck(:key)).to eq(["live"])
  end
end
