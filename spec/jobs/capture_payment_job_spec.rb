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
  def capture_request(amount)
    payment.captures.create!(amount_minor: amount, base_captured_minor: Ledger.captured_minor(payment))
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
    first = capture_request(1000)
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

  it "adopts a job enqueued before captures were rows (payment_id, amount)" do
    adapter.script(:fetch, charge(:authorized, captured_minor: 0))
    adapter.script(:capture, charge(:captured, captured_minor: 2500))

    described_class.perform_now(payment.id, 2500)

    expect(payment.captures.sole).to have_attributes(amount_minor: 2500, state: "succeeded")
    expect(Ledger.captured_minor(payment)).to eq(2500)
  end
end
