# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops audit stream", type: :request do
  let(:merchant) { create(:merchant) }

  it "lets support read every audit row" do
    AuditEvent.record!(action: "operator.invited", result: "success", actor_label: "ops@example.com")
    AuditEvent.record!(action: "payment.captured", result: "success", actor_label: "m@example.com", merchant_id: merchant.id)
    sign_in_operator(create(:operator, role: "support"))

    get "/ops/api/audit_events", headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(json_body["data"].map { |e| e["action"] }).to include("operator.invited", "payment.captured")
  end

  it "filters by action prefix, actor type and merchant" do
    AuditEvent.record!(action: "payment.captured", result: "success", actor_label: "m", merchant_id: merchant.id)
    AuditEvent.record!(action: "payment.refunded", result: "success", actor_label: "m", merchant_id: merchant.id)
    AuditEvent.record!(action: "operator.invited", result: "success", actor_label: "o")
    sign_in_operator(create(:operator, role: "support"))

    get "/ops/api/audit_events", params: { action_prefix: "payment." }, headers: ui_headers
    actions = json_body["data"].map { |e| e["action"] }
    expect(actions).to contain_exactly("payment.captured", "payment.refunded")

    get "/ops/api/audit_events", params: { merchant_id: merchant.id }, headers: ui_headers
    expect(json_body["data"].size).to eq(2)
  end

  it "rejects a malformed date range" do
    sign_in_operator(create(:operator, role: "support"))
    get "/ops/api/audit_events", params: { from: "not-a-time" }, headers: ui_headers
    expect(response).to have_http_status(422)
  end
end
