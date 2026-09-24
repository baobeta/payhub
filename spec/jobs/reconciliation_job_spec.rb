require "rails_helper"

RSpec.describe ReconciliationJob do
  let(:payment) { create(:payment) }

  before { allow(PspRouter).to receive(:adapter).and_return(FakePspAdapter.new) }

  it "flags a refund whose reservation disagrees with its state (DECISIONS #16)" do
    Ledger.record_capture!(payment, 2500)
    healthy = create(:refund, payment: payment, amount_minor: 500)                   # pending, holds 500
    unreserved = create(:refund, payment: payment, amount_minor: 300, state: "failed")
    unreserved.update_column(:state, "pending")                                      # pending, holds nothing
    allow(Rails.logger).to receive(:error).and_call_original

    described_class.perform_now(1.hour.from_now.iso8601) # empty payment window: only the ledger checks run

    expect(Ledger.reservation_drift_refund_ids).to eq([unreserved.id])
    expect(Rails.logger).to have_received(:error).with(a_string_including("reconciliation.reservation_drift", unreserved.id))
    expect(Rails.logger).not_to have_received(:error).with(a_string_including(healthy.id))
  end
end
