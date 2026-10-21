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

  it "TC-B3-3: lists a failed payment the PSP charged anyway, and only that one" do
    charged = create(:payment, merchant:, state: "failed")
    declined = create(:payment, merchant:, state: "failed") # an ordinary decline: not a queue item
    [[charged, "#{ProcessInboundEventJob::LATE_SUCCESS}: PSP reports captured on a failed payment"],
     [declined, nil]].each do |payment, error|
      InboundEvent.create!(psp_name: payment.psp_name, external_id: SecureRandom.hex(4), event_type: "charge.captured",
                           psp_reference: payment.psp_reference, signature_valid: true, received_at: Time.current,
                           processed_at: Time.current, error: error, payload: { "data" => {} })
    end

    expect(described_class.call["late_successes"].map { |p| p["id"] }).to eq([charged.id])
  end

  it "TC-C6-1: lists a payment still pending after 15 minutes, oldest first, and not a fresh one" do
    stuck = create(:payment, merchant:, state: "pending")
    older = create(:payment, merchant:, state: "pending")
    fresh = create(:payment, merchant:, state: "pending")
    stuck.update_columns(created_at: 20.minutes.ago)
    older.update_columns(created_at: 40.minutes.ago)
    fresh.update_columns(created_at: 2.minutes.ago)

    rows = described_class.call["stuck_pending"]

    expect(rows.map { |p| p["id"] }).to eq([older.id, stuck.id])
    expect(rows.first).to include("merchant" => merchant.name, "psp_reference" => older.psp_reference)
    expect(rows.map { |p| p["id"] }).not_to include(fresh.id)
  end
end
