# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpsQueue do
  let(:merchant) { create(:merchant) }

  it "orders unknown payments oldest first and lists all four sections" do
    older = create(:payment, merchant:, state: "unknown")
    newer = create(:payment, merchant:, state: "unknown")
    older.update_columns(updated_at: 2.hours.ago)
    newer.update_columns(updated_at: 1.hour.ago)
    create(:payment, merchant:, state: "captured") # not a queue item

    dead = OutboundEvent.create!(merchant:, event_type: "payment.captured", payload: { "id" => "evt" }, state: "dead",
                                 next_attempt_at: Time.current, last_error: "boom")
    SettlementLine.create!(psp_name: "nordpay", external_id: "e1", psp_reference: "ph_x", settled_on: Date.current,
                           kind: "capture", gross_minor: 100, fee_minor: 5, net_minor: 95, currency: "EUR",
                           booked_at: Time.current, status: "unmatched")
    create(:operator_proposal, :ledger_correction, payment: create(:payment, merchant:), state: "pending")

    result = described_class.call

    expect(result["unknown_payments"].map { |p| p["id"] }).to eq([older.id, newer.id])
    expect(result["dead_events"].first).to include("id" => dead.id, "type" => "payment.captured", "last_error" => "boom")
    expect(result["reconciliation_breaks"]).to eq(1)
    expect(result["open_proposals"]).to eq(1)
  end
end
