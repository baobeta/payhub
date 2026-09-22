require "rails_helper"

# The whiteboard flow. The PSP is a scripted FakePspAdapter — the real HTTP
# behaviour is covered by spec/adapters/nordpay_adapter_spec.rb — so each
# scenario is exactly the sequence of PSP answers named in the spec.
RSpec.describe AuthorizePaymentJob do
  let(:payment) { create(:payment) }
  let(:adapter) { FakePspAdapter.new }
  let(:t_psp) { payment.created_at + 2.seconds }

  def result(status, **overrides)
    PspAdapter::Result.new(
      { status: PspAdapter::Result::Status.deserialize(status.to_s), psp_reference: payment.psp_reference,
        psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: t_psp }.merge(overrides)
    )
  end

  before { allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter) }

  it "authorized → authorized, with the PSP's timestamp as sort_key and the charge id in metadata" do
    adapter.script(:authorize, result(:authorized))

    described_class.perform_now(payment.id)

    expect(payment.reload.state).to eq("authorized")
    current = payment.transitions.find_by(most_recent: true)
    expect(current.sort_key).to eq(t_psp)
    expect(current.source).to eq("worker")
    expect(current.metadata).to include("psp_charge_id" => "ch_1")
  end

  it "declined (HTTP 200) → failed, carrying the decline code" do
    adapter.script(:authorize, result(:declined, decline_code: "insufficient_funds"))

    described_class.perform_now(payment.id)

    expect(payment.reload.state).to eq("failed")
    expect(payment.transitions.find_by(most_recent: true).metadata).to include("decline_code" => "insufficient_funds")
  end

  context "when the PSP times out but the charge succeeded (the whiteboard case)" do
    it "moves to unknown, polls, and lands on authorized — never re-sends the authorize" do
      adapter.script(:authorize, PspAdapter::TimedOut)
      adapter.script(:fetch, result(:authorized))

      described_class.perform_now(payment.id)

      expect(adapter.calls[:authorize].size).to eq(1)
      expect(adapter.calls[:fetch]).to eq([payment.psp_reference])
      expect(payment.reload.state).to eq("authorized")
      expect(payment.transitions.map(&:to_state)).to eq(%w[pending unknown authorized])
    end
  end

  context "when the PSP times out and the charge never landed" do
    it "moves to unknown, polls, gets 404, re-sends the authorize with the SAME reference" do
      adapter.script(:authorize, PspAdapter::TimedOut, result(:authorized))
      adapter.script(:fetch, result(:not_found))

      described_class.perform_now(payment.id)

      expect(adapter.calls[:authorize].size).to eq(2)
      expect(adapter.calls[:authorize].map(&:psp_reference).uniq).to eq([payment.psp_reference])
      expect(payment.reload.state).to eq("authorized")
    end
  end

  context "when the PSP times out on the authorize AND on the poll" do
    it "leaves the payment in unknown for the sweeper — it does not guess" do
      adapter.script(:authorize, PspAdapter::TimedOut)
      adapter.script(:fetch, PspAdapter::TimedOut)

      described_class.perform_now(payment.id)

      expect(payment.reload.state).to eq("unknown")
      expect(adapter.calls[:authorize].size).to eq(1)
    end
  end

  it "is a no-op when run twice — the second run sees a resolved payment and does not call the PSP" do
    adapter.script(:authorize, result(:authorized)) # only ONE answer scripted; a second call would raise

    described_class.perform_now(payment.id)
    described_class.perform_now(payment.id)

    expect(adapter.calls[:authorize].size).to eq(1)
    expect(payment.reload.transitions.count).to eq(2) # pending, authorized — nothing extra
  end

  it "is a no-op if a webhook already resolved the payment before the job ran" do
    payment.transition!(:authorized, sort_key: t_psp, source: "webhook")

    described_class.perform_now(payment.id)

    expect(adapter.calls[:authorize]).to be_empty
  end

  it "lets Unavailable propagate so ActiveJob retries with backoff and the same reference" do
    adapter.script(:authorize, PspAdapter::Unavailable)

    expect { described_class.perform_now(payment.id) }.to have_enqueued_job(described_class).with(payment.id)
    expect(payment.reload.state).to eq("pending")
  end
end
