require "rails_helper"

RSpec.describe RefundPaymentJob do
  let(:payment) { create(:payment) }
  let(:adapter) { FakePspAdapter.new }
  let(:t_psp) { payment.created_at + 3.seconds }

  before do
    allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter)
    payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")
    Ledger.record_capture!(payment, 2500)
    payment.transition!(:captured, sort_key: payment.created_at + 2.seconds, source: "worker")
  end

  def outcome(status, ref, code: nil)
    PspAdapter::RefundResult.new(
      status: PspAdapter::RefundResult::Status.deserialize(status.to_s), psp_reference: ref,
      psp_refund_id: "re_1", failure_code: code, psp_timestamp: t_psp
    )
  end

  it "books a succeeded partial refund and moves captured → part_refunded" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, outcome(:succeeded, refund.psp_reference))

    described_class.perform_now(refund.id)

    expect(refund.reload.state).to eq("succeeded")
    expect(Ledger.refunded_minor(payment)).to eq(500)
    expect(payment.reload.state).to eq("part_refunded")
    expect(Ledger.balances(payment.merchant)).to eq("EUR" => 2000)
  end

  it "moves to refunded when the refunded total reaches the captured total" do
    first = create(:refund, payment: payment, amount_minor: 1500)
    second = create(:refund, payment: payment, amount_minor: 1000)
    adapter.script(:refund, outcome(:succeeded, first.psp_reference), outcome(:succeeded, second.psp_reference))

    described_class.perform_now(first.id)
    described_class.perform_now(second.id)

    expect(payment.reload.state).to eq("refunded")
    expect(Ledger.refunded_minor(payment)).to eq(2500)
  end

  it "marks a failed refund failed and books nothing" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, outcome(:failed, refund.psp_reference, code: "exceeds_captured"))

    described_class.perform_now(refund.id)

    expect(refund.reload.state).to eq("failed")
    expect(Ledger.refunded_minor(payment)).to eq(0)
    expect(payment.reload.state).to eq("captured")
  end

  it "is idempotent: a second run finds the refund resolved and never calls the PSP (perform-twice test)" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, outcome(:succeeded, refund.psp_reference)) # only one answer; a 2nd call would raise

    described_class.perform_now(refund.id)
    ledger_before = LedgerEntry.pluck(:id).sort
    described_class.perform_now(refund.id)

    expect(LedgerEntry.pluck(:id).sort).to eq(ledger_before)
    expect(adapter.calls[:refund].size).to eq(1)
  end

  it "on timeout, resolves by fetching OUR refund reference — never re-sends the refund" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, PspAdapter::TimedOut)
    adapter.script(:fetch_refund, outcome(:succeeded, refund.psp_reference))

    described_class.perform_now(refund.id)

    expect(adapter.calls[:refund].size).to eq(1)
    expect(adapter.calls[:fetch_refund]).to eq([refund.psp_reference])
    expect(refund.reload.state).to eq("succeeded")
  end

  it "on timeout where the PSP never saw it, leaves the refund pending for the sweeper" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, PspAdapter::TimedOut)
    adapter.script(:fetch_refund, outcome(:not_found, refund.psp_reference))

    described_class.perform_now(refund.id)

    expect(refund.reload.state).to eq("pending")
    expect(Ledger.refunded_minor(payment)).to eq(0)
  end
end
