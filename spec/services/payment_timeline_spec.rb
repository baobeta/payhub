# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaymentTimeline do
  it "merges transitions, ledger transfers and events into one list ordered by time" do
    payment = create(:payment)
    payment.transition!(:authorized, sort_key: 1.minute.from_now, source: "worker")
    Ledger.record_capture!(payment, 2500)
    OutboundEvent.emit!(payment, "payment.captured")

    entries = described_class.call(payment)
    expect(entries.map { |e| e["kind"] }).to include("transition", "ledger_transfer", "event")
    times = entries.map { |e| e["at"] }
    expect(times).to eq(times.sort)
  end

  it "shows each ledger transfer once, with its legs" do
    payment = create(:payment)
    Ledger.record_capture!(payment, 2500)
    transfers = described_class.call(payment).select { |e| e["kind"] == "ledger_transfer" }
    expect(transfers.size).to eq(1)
    expect(transfers.first["legs"].map { |l| l["account"] }).to contain_exactly("psp_receivable", "merchant_payable")
  end
end
