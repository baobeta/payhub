# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops events", type: :request do
  let(:merchant) { create(:merchant) }
  let!(:dead) do
    OutboundEvent.create!(merchant:, event_type: "payment.captured", payload: { "id" => "evt" },
                          state: "dead", next_attempt_at: Time.current, last_error: "boom")
  end

  before { sign_in_operator(create(:operator, role: "ops")) }

  it "requires a reason" do
    post "/ops/api/events/#{dead.id}/redeliver", headers: ui_headers
    expect(response).to have_http_status(422)
    expect(dead.reload.state).to eq("dead")
  end

  it "redelivers a dead event and audits the reason" do
    post "/ops/api/events/#{dead.id}/redeliver", params: { reason: "Webhook fixed" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(dead.reload.state).to eq("pending")
    expect(AuditEvent.sole).to have_attributes(action: "event.redelivered", metadata: { "reason" => "Webhook fixed" })
  end

  it "forbids an approver" do
    sign_in_operator(create(:operator, role: "approver"))
    post "/ops/api/events/#{dead.id}/redeliver", params: { reason: "nope" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:forbidden)
  end
end
