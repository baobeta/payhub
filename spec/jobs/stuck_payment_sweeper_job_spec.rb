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
