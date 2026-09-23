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

  # What a real PSP reports after a timeout: a charge stamped a few ms after it
  # RECEIVED our authorize — i.e. after we sent it, before we gave up. Built
  # lazily so the timestamp comes from the actual call, not from spec setup.
  def result_recorded_during_authorize(status, **overrides)
    -> { result(status, psp_timestamp: adapter.received_at(:authorize) + 0.005, **overrides) }
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

  it "dates `unknown` from the FIRST send of the reference, so a charge an earlier sender created is not judged stale" do
    # Found by the deterministic simulation (DECISIONS #11, #19): the sweeper
    # re-sent this pending payment after a 404 and lost the response; the PSP
    # stamped the charge then. The queued job ran two minutes later and timed
    # out too. Dated from ITS send, `unknown` was newer than every verdict the
    # PSP could ever report, and the payment stayed unknown forever.
    first_send = payment.created_at + 1.second
    travel_to(first_send, with_usec: true) { payment.mark_sent! }
    adapter.script(:authorize, PspAdapter::TimedOut)
    adapter.script(:fetch, result(:authorized, psp_timestamp: first_send + 0.005))

    travel_to(first_send + 2.minutes, with_usec: true) { described_class.perform_now(payment.id) }

    expect(payment.reload.state).to eq("authorized")
    expect(payment.transitions.find_by(to_state: "unknown").sort_key).to eq(first_send)
  end

  it "keeps the earliest send time when two senders race" do
    t = payment.created_at + 1.second
    travel_to(t, with_usec: true) { payment.mark_sent! }
    later = Payment.find(payment.id)
    travel_to(t + 1.minute, with_usec: true) { expect(later.mark_sent!).to eq(t) }
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
      # The PSP recorded the charge BEFORE hanging, so its timestamp predates
      # our give-up time. `unknown` must be dated from send time or this
      # verdict would be judged stale and the payment stuck (a real bug we hit).
      adapter.script(:fetch, result_recorded_during_authorize(:authorized))

      described_class.perform_now(payment.id)

      expect(adapter.calls[:authorize].size).to eq(1)
      expect(adapter.calls[:fetch]).to eq([payment.psp_reference])
      expect(payment.reload.state).to eq("authorized")
      expect(payment.transitions.order(:sort_key).map(&:to_state)).to eq(%w[pending unknown authorized])
      expect(payment.transitions.where(most_recent: true).pick(:to_state)).to eq("authorized")
    end
  end

  context "when the PSP times out and the charge never landed" do
    it "moves to unknown, polls, gets 404, re-sends the authorize with the SAME reference" do
      adapter.script(:authorize, PspAdapter::TimedOut, result_recorded_during_authorize(:authorized))
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
