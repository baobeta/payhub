require "rails_helper"

RSpec.describe CapturePaymentJob do
  let(:payment) { create(:payment) }
  let(:adapter) { FakePspAdapter.new }
  let(:t_psp) { payment.created_at + 2.seconds }

  before do
    allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter)
    payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")
  end

  def charge(status, captured_minor:)
    PspAdapter::Result.new(
      status: PspAdapter::Result::Status.deserialize(status.to_s), psp_reference: payment.psp_reference,
      psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: t_psp, raw: { "captured_minor" => captured_minor }
    )
  end

  # What CapturePayment records when the merchant asks.
  def capture_request(amount, final: true)
    payment.captures.create!(amount_minor: amount, base_captured_minor: Ledger.captured_minor(payment), final: final)
  end

  it "reads the PSP first, then captures, books the amount and moves authorized → captured" do
    capture = capture_request(2500)
    adapter.script(:fetch, charge(:authorized, captured_minor: 0))
    adapter.script(:capture, charge(:captured, captured_minor: 2500))

    described_class.perform_now(capture.id)

    expect(Ledger.captured_minor(payment)).to eq(2500)
    expect(payment.reload).to have_attributes(state: "captured", captured_minor: 2500)
    expect(capture.reload.state).to eq("succeeded")
    expect(adapter.calls[:capture]).to eq([[payment, 2500]])
  end

  it "books partial captures cumulatively — the ledger holds the running total" do
    first = capture_request(1000, final: false) # a final one would close capturing (DECISIONS #20)
    adapter.script(:fetch, charge(:authorized, captured_minor: 0))
    adapter.script(:capture, charge(:authorized, captured_minor: 1000))
    described_class.perform_now(first.id)

    second = capture_request(1500)
    adapter.script(:fetch, charge(:authorized, captured_minor: 1000))
    adapter.script(:capture, charge(:captured, captured_minor: 2500))
    described_class.perform_now(second.id)

    expect(Ledger.captured_minor(payment)).to eq(2500)
    expect(LedgerEntry.where(payment: payment).count).to eq(4) # two balanced transfers
    expect([first.reload.state, second.reload.state]).to eq(%w[succeeded succeeded])
  end

  describe "never capturing twice (DECISIONS #20)" do
    it "a redelivered job finds its capture settled and never calls the PSP again" do
      capture = capture_request(1000)
      adapter.script(:fetch, charge(:authorized, captured_minor: 0)) # only one answer each; a second call would raise
      adapter.script(:capture, charge(:authorized, captured_minor: 1000))

      2.times { described_class.perform_now(capture.id) }

      expect(adapter.calls[:capture].size).to eq(1)
      expect(Ledger.captured_minor(payment)).to eq(1000)
    end

    it "a retry after the capture landed but both the response and the follow-up read were lost books it without re-sending" do
      # Found by the deterministic simulation: this path used to send the
      # partial capture again, and the PSP took it — twice what was asked.
      capture = capture_request(1000)
      adapter.script(:fetch, charge(:authorized, captured_minor: 0), PspAdapter::TimedOut)
      adapter.script(:capture, PspAdapter::TimedOut) # landed at the PSP; the response did not
      expect { described_class.perform_now(capture.id) }.to raise_error(PspAdapter::TimedOut) # Sidekiq retries

      adapter.script(:fetch, charge(:authorized, captured_minor: 1000)) # the retry reads first
      described_class.perform_now(capture.id)

      expect(adapter.calls[:capture].size).to eq(1)
      expect(Ledger.captured_minor(payment)).to eq(1000)
      expect(capture.reload.state).to eq("succeeded")
    end

    it "never sends when the read before it fails — a blind send is how captures double" do
      capture = capture_request(1000)
      adapter.script(:fetch, PspAdapter::Unavailable)

      described_class.perform_now(capture.id) # retry_on Unavailable: re-enqueued, not raised

      expect(adapter.calls[:capture]).to be_empty
      expect(capture.reload.state).to eq("pending")
    end
  end

  it "on timeout where the capture never landed, books nothing and leaves it pending for the sweeper" do
    capture = capture_request(2500)
    adapter.script(:fetch, charge(:authorized, captured_minor: 0), charge(:authorized, captured_minor: 0))
    adapter.script(:capture, PspAdapter::TimedOut)

    described_class.perform_now(capture.id)

    expect(Ledger.captured_minor(payment)).to eq(0)
    expect(capture.reload.state).to eq("pending")
    expect(payment.reload.state).to eq("authorized")
  end

  it "marks the capture failed when the PSP refuses it" do
    capture = capture_request(2500)
    adapter.script(:fetch, charge(:authorized, captured_minor: 0))
    adapter.script(:capture, PspAdapter::Rejected.new(422, "capture exceeds authorized"))

    described_class.perform_now(capture.id)

    expect(capture.reload).to have_attributes(state: "failed", failure_code: "psp_rejected_422")
  end

  it "fails without calling the PSP when the payment is no longer capturable" do
    capture = capture_request(2500)
    payment.transition!(:canceled, sort_key: payment.created_at + 3.seconds, source: "api")

    described_class.perform_now(capture.id)

    expect(capture.reload).to have_attributes(state: "failed", failure_code: "payment_canceled")
    expect(adapter.calls[:fetch]).to be_empty
  end

  describe "several partial captures (DECISIONS #20)" do
    def capture_request(amount, final: true)
      payment.captures.create!(amount_minor: amount, base_captured_minor: Ledger.captured_minor(payment), final: final)
    end

    it "TC-E3-21: a queued capture on a payment whose capturing was closed fails without calling the PSP" do
      capture = capture_request(1000, final: false)
      payment.update_column(:captures_closed_at, Time.current)

      described_class.perform_now(capture.id)

      expect(capture.reload).to have_attributes(state: "failed", failure_code: "captures_closed")
      expect(adapter.calls[:fetch]).to be_empty
      expect(OutboundEvent.where(payment: payment, event_type: "capture.failed").count).to eq(1)
    end

    it "TC-E3-12: one capture.succeeded per capture, payment.captured once" do
      first = capture_request(1000, final: false)
      adapter.script(:fetch, charge(:authorized, captured_minor: 0))
      adapter.script(:capture, charge(:authorized, captured_minor: 1000))
      described_class.perform_now(first.id)
      second = capture_request(1500)
      adapter.script(:fetch, charge(:authorized, captured_minor: 1000))
      adapter.script(:capture, charge(:captured, captured_minor: 2500))
      described_class.perform_now(second.id)

      events = OutboundEvent.where(payment: payment, event_type: "capture.succeeded").order(:created_at)
      expect(events.map { |e| e.payload["capture"].slice("id", "amount_minor") })
        .to eq([{ "id" => first.id, "amount_minor" => 1000 }, { "id" => second.id, "amount_minor" => 1500 }])
      expect(events.map { |e| e.payload["capturable_minor"] }).to eq([1500, 0])
      expect(OutboundEvent.where(payment: payment, event_type: "payment.captured").count).to eq(1)
      expect(payment.reload.captures_closed_at).to be_present
    end

    it "TC-E3-13: a failed capture emits capture.failed and leaves capturing open" do
      capture = capture_request(2500)
      adapter.script(:fetch, charge(:authorized, captured_minor: 0))
      adapter.script(:capture, PspAdapter::Rejected.new(422, "not capturable"))

      described_class.perform_now(capture.id)

      event = OutboundEvent.find_by!(payment: payment, event_type: "capture.failed")
      expect(event.payload).to include("failure_code" => "psp_rejected_422", "capturable_minor" => 2500)
      expect(event.payload["capture"]).to include("id" => capture.id, "state" => "failed")
      expect(payment.reload.captures_closed_at).to be_nil
      expect(CapturePayment.call(payment, amount_minor: 2500).captures.pending.count).to eq(1) # may retry
    end

    it "TC-E3-14: the read-before-send rule holds for a second capture whose response was lost" do
      first = capture_request(1000, final: false)
      adapter.script(:fetch, charge(:authorized, captured_minor: 0))
      adapter.script(:capture, charge(:authorized, captured_minor: 1000))
      described_class.perform_now(first.id)

      second = capture_request(1500)
      adapter.script(:fetch, charge(:authorized, captured_minor: 1000), PspAdapter::TimedOut)
      adapter.script(:capture, PspAdapter::TimedOut)
      expect { described_class.perform_now(second.id) }.to raise_error(PspAdapter::TimedOut)
      adapter.script(:fetch, charge(:captured, captured_minor: 2500))
      described_class.perform_now(second.id)

      expect(adapter.calls[:capture].size).to eq(2) # one per capture, never a re-send
      expect(Ledger.captured_minor(payment)).to eq(2500)
      expect(second.reload.state).to eq("succeeded")
    end

    it "takes a capture from part_refunded, between refunds" do
      first = capture_request(1000, final: false)
      adapter.script(:fetch, charge(:authorized, captured_minor: 0))
      adapter.script(:capture, charge(:authorized, captured_minor: 1000))
      described_class.perform_now(first.id)
      refund = create(:refund, payment: payment, amount_minor: 400)
      Ledger.post_refund!(refund)
      refund.update!(state: "succeeded")
      payment.transition!(:part_refunded, sort_key: t_psp + 1.second, source: "worker")

      second = capture_request(1500)
      adapter.script(:fetch, charge(:authorized, captured_minor: 1000))
      adapter.script(:capture, charge(:captured, captured_minor: 2500))
      described_class.perform_now(second.id)

      expect(second.reload.state).to eq("succeeded")
      expect(payment.reload).to have_attributes(state: "part_refunded", captured_minor: 2500)
    end
  end

  describe "TC-E1-2: payment.captured event written once with the state change" do
    it "TC-E1-2: a single capture emits exactly one payment.captured event, in the same transaction" do
      capture = capture_request(2500)
      adapter.script(:fetch, charge(:authorized, captured_minor: 0))
      adapter.script(:capture, charge(:captured, captured_minor: 2500))

      described_class.perform_now(capture.id)

      events = OutboundEvent.where(payment: payment, event_type: "payment.captured")
      expect(events.count).to eq(1)
      # The event exists iff the state change committed — transactional outbox.
      expect(payment.reload.state).to eq("captured")
      expect(events.first.created_at).to be_within(1.second).of(payment.transitions.find_by(to_state: "captured").created_at)
    end

    it "TC-E1-2: a second perform_now on an already-captured payment does not write a duplicate event" do
      capture = capture_request(2500)
      adapter.script(:fetch, charge(:authorized, captured_minor: 0))
      adapter.script(:capture, charge(:captured, captured_minor: 2500))
      described_class.perform_now(capture.id)

      # Re-run: idempotent, no duplicate events written.
      described_class.perform_now(capture.id)

      expect(OutboundEvent.where(payment: payment, event_type: "payment.captured").count).to eq(1)
    end
  end

  it "adopts a job enqueued before captures were rows (payment_id, amount)" do
    adapter.script(:fetch, charge(:authorized, captured_minor: 0))
    adapter.script(:capture, charge(:captured, captured_minor: 2500))

    described_class.perform_now(payment.id, 2500)

    expect(payment.captures.sole).to have_attributes(amount_minor: 2500, state: "succeeded")
    expect(Ledger.captured_minor(payment)).to eq(2500)
  end
end
