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

  it "books the captured amount in the ledger and moves authorized → captured" do
    adapter.script(:capture, charge(:captured, captured_minor: 2500))

    described_class.perform_now(payment.id, 2500)

    expect(Ledger.captured_minor(payment)).to eq(2500)
    expect(payment.reload.state).to eq("captured")
    expect(payment.captured_minor).to eq(2500)
    expect(adapter.calls[:capture]).to eq([[payment, 2500]])
  end

  it "books partial captures cumulatively — the ledger holds the running total" do
    adapter.script(:capture, charge(:authorized, captured_minor: 1000), charge(:captured, captured_minor: 2500))

    described_class.perform_now(payment.id, 1000)
    described_class.perform_now(payment.id, 1500)

    expect(Ledger.captured_minor(payment)).to eq(2500)
    expect(LedgerEntry.where(payment: payment).count).to eq(4) # two balanced transfers
    expect(payment.reload.state).to eq("captured")
  end

  it "is idempotent: running twice with the same PSP total books once (the spec's perform-twice test)" do
    adapter.script(:capture, charge(:captured, captured_minor: 2500), charge(:captured, captured_minor: 2500))

    described_class.perform_now(payment.id, 2500)
    ledger_before = LedgerEntry.where(payment: payment).pluck(:id, :amount_minor).sort
    described_class.perform_now(payment.id, 2500)

    expect(LedgerEntry.where(payment: payment).pluck(:id, :amount_minor).sort).to eq(ledger_before)
    expect(Ledger.captured_minor(payment)).to eq(2500)
  end

  it "on timeout, fetches the PSP's running total and books only the unbooked difference" do
    adapter.script(:capture, PspAdapter::TimedOut)
    adapter.script(:fetch, charge(:captured, captured_minor: 2500)) # the capture DID land

    described_class.perform_now(payment.id, 2500)

    expect(Ledger.captured_minor(payment)).to eq(2500)
    expect(payment.reload.state).to eq("captured")
  end

  it "on timeout where the capture never landed, books nothing" do
    adapter.script(:capture, PspAdapter::TimedOut)
    adapter.script(:fetch, charge(:authorized, captured_minor: 0))

    described_class.perform_now(payment.id, 2500)

    expect(Ledger.captured_minor(payment)).to eq(0)
    expect(payment.reload.state).to eq("authorized")
  end
end
