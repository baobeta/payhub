# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops sessions list", type: :request do
  let(:operator) { create(:operator) }
  let!(:other) { Session.create!(principal: operator, ip: "203.0.113.9", user_agent: "Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0") }

  it "TC-M7-5 lists the operator's own sessions only" do
    Session.create!(principal: create(:merchant_user), ip: "1.1.1.1", user_agent: "x")
    current = sign_in_operator(operator)

    get "/ops/api/sessions"

    expect(json_body["data"].pluck("id")).to contain_exactly(current.id, other.id)
    expect(json_body["data"].find { |r| r["id"] == other.id }).to include("browser" => "Firefox", "os" => "Linux")
  end

  it "TC-M7-5 ends one session only after step-up, and audits it" do
    sign_in_operator(operator)
    delete "/ops/api/sessions/#{other.id}", headers: ui_headers
    expect(json_body.dig("error", "code")).to eq("step_up_required")

    sign_in_operator(operator, stepped_up: true)
    delete "/ops/api/sessions/#{other.id}", headers: ui_headers
    expect(response).to have_http_status(:no_content)
    expect(other.reload.revoked_at).to be_present
    expect(AuditEvent.last).to have_attributes(action: "session.revoked", actor_id: operator.id)
  end

  it "TC-M7-5 ends every other session and emails the operator" do
    current = sign_in_operator(operator, stepped_up: true)
    expect do
      post "/ops/api/sessions/revoke_others", headers: ui_headers
    end.to have_enqueued_mail(SecurityMailer, :sessions_revoked)
    expect(other.reload.revoked_at).to be_present
    expect(current.reload.revoked_at).to be_nil
  end
end
