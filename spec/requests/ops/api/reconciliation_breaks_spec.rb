# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops reconciliation breaks", type: :request do
  let(:line) do
    SettlementLine.create!(psp_name: "nordpay", external_id: "e1", psp_reference: "ph_x", settled_on: Date.current,
                           kind: "capture", gross_minor: 100, fee_minor: 5, net_minor: 95, currency: "EUR",
                           booked_at: Time.current, status: "unmatched")
  end

  def review(reason: "checked")
    post "/ops/api/reconciliation_breaks/#{line.id}/review", params: { reason: }.to_json, headers: ui_headers
  end

  it "lists settlement breaks and the read-only ledger lists" do
    line
    sign_in_operator(create(:operator, role: "support"))
    get "/ops/api/reconciliation_breaks", headers: ui_headers
    expect(json_body["settlement_lines"].sole["id"]).to eq(line.id)
    expect(json_body["ledger"]).to include("unbalanced_transfer_ids", "reservation_drift_refund_ids")
  end

  it "lets ops review a break and audits it" do
    sign_in_operator(create(:operator, role: "ops"))
    expect { review }.to change(AuditEvent.where(action: "reconciliation.reviewed"), :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(line.reload).to have_attributes(review_note: "checked")
    expect(line.reviewed_by_id).to be_present
  end

  it "forbids support from reviewing" do
    sign_in_operator(create(:operator, role: "support"))
    review
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses a second review with 409" do
    sign_in_operator(create(:operator, role: "ops"))
    review(reason: "one")
    review(reason: "two")
    expect(response).to have_http_status(409)
  end
end
