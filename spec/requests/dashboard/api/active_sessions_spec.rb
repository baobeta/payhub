# frozen_string_literal: true

require "rails_helper"

# M7: see and end your other sessions (ASVS 5.0 7.5.2, GitHub, Stripe).
RSpec.describe "Dashboard sessions list", type: :request do
  let(:user) { create(:merchant_user) }
  let(:chrome_mac) do
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " \
      "Chrome/126.0.0.0 Safari/537.36"
  end
  let!(:other) { Session.create!(principal: user, ip: "203.0.113.9", user_agent: chrome_mac) }

  it "TC-M7-1 lists this user's live sessions, flags only the current one, and never another user's" do
    create(:merchant_user).then { |u| Session.create!(principal: u, ip: "1.1.1.1", user_agent: "x") }
    Session.create!(principal: user, ip: "1.1.1.1", user_agent: "x", revoked_at: Time.current)
    current = sign_in_as(user)

    get "/dashboard/api/sessions"

    expect(response).to have_http_status(:ok)
    rows = json_body["data"]
    expect(rows.pluck("id")).to contain_exactly(current.id, other.id)
    expect(rows.select { |r| r["current"] }.pluck("id")).to eq([current.id])
    expect(rows.find { |r| r["id"] == other.id }).to include("browser" => "Chrome", "os" => "macOS", "ip" => "203.0.113.9")
    expect(rows.first.keys).to include("created_at", "last_active_at")
  end

  it "TC-M7-2 ends another session with step-up; its next request is 401 and the revoke is audited" do
    sign_in_as(user, stepped_up: true)

    delete "/dashboard/api/sessions/#{other.id}", headers: ui_headers

    expect(response).to have_http_status(:no_content)
    expect(AuditEvent.last).to have_attributes(action: "session.revoked", target_id: other.id, merchant_id: user.merchant_id)
    set_signed_cookie(:_payhub_dashboard, other.id)
    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "TC-M7-3 needs step-up, and another user's session is not found" do
    sign_in_as(user)
    delete "/dashboard/api/sessions/#{other.id}", headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
    expect(json_body.dig("error", "code")).to eq("step_up_required")
    expect(other.reload.revoked_at).to be_nil

    stranger = Session.create!(principal: create(:merchant_user), ip: "1.1.1.1", user_agent: "x")
    sign_in_as(user, stepped_up: true)
    delete "/dashboard/api/sessions/#{stranger.id}", headers: ui_headers
    expect(response).to have_http_status(:not_found)
    expect(stranger.reload.revoked_at).to be_nil
  end

  it "TC-M7-3 refuses to end the current session here (sign out does that)" do
    current = sign_in_as(user, stepped_up: true)
    delete "/dashboard/api/sessions/#{current.id}", headers: ui_headers
    expect(response).to have_http_status(:conflict)
    expect(current.reload.revoked_at).to be_nil
  end

  it "TC-M7-4 revoke_others ends every other session, keeps this one, audits and emails" do
    third = Session.create!(principal: user, ip: "1.1.1.1", user_agent: "x")
    current = sign_in_as(user, stepped_up: true)

    expect do
      post "/dashboard/api/sessions/revoke_others", headers: ui_headers
    end.to have_enqueued_mail(SecurityMailer, :sessions_revoked)

    expect(response).to have_http_status(:ok)
    expect(json_body["revoked"]).to eq(2)
    expect([other, third].map { |s| s.reload.revoked_at }).to all(be_present)
    expect(current.reload.revoked_at).to be_nil
    expect(AuditEvent.last).to have_attributes(action: "session.revoked_others", merchant_id: user.merchant_id)
  end

  it "TC-M7-4 revoke_others needs step-up" do
    sign_in_as(user)
    post "/dashboard/api/sessions/revoke_others", headers: ui_headers
    expect(json_body.dig("error", "code")).to eq("step_up_required")
    expect(other.reload.revoked_at).to be_nil
  end
end
