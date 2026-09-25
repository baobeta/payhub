# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invitations and enrolment", type: :request do
  let(:admin) { create(:merchant_user, role: "admin") }

  def invite(email: "new@example.com", role: "support")
    post "/dashboard/api/invitations", params: { email:, role: }.to_json, headers: ui_headers
  end

  it "needs step-up to invite" do
    sign_in_as(admin)
    invite
    expect(json_body.dig("error", "code")).to eq("step_up_required")
  end

  it "invites, emails a link, and audits" do
    sign_in_as(admin, stepped_up: true)
    expect { invite }.to have_enqueued_mail(InvitationMailer, :invite)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("email" => "new@example.com", "status" => "invited")
    expect(AuditEvent.last).to have_attributes(action: "team.invited", merchant_id: admin.merchant_id)
  end

  it "refuses to invite an owner, and a viewer cannot invite at all" do
    sign_in_as(admin, stepped_up: true)
    invite(role: "owner")
    expect(response).to have_http_status(:unprocessable_content)

    sign_in_as(create(:merchant_user, merchant: admin.merchant, role: "viewer"), stepped_up: true)
    invite(email: "other@example.com")
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses a malformed email" do
    sign_in_as(admin, stepped_up: true)
    invite(email: "=cmd|' /C calc'!A0")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body.dig("error", "details", "email")).to be_present
  end

  it "refuses an email that already has an account" do
    sign_in_as(admin, stepped_up: true)
    invite(email: admin.email)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "accepts, enrols 2FA, returns recovery codes once, and signs in" do
    user, token = MerchantUser.invite!(merchant: admin.merchant, email: "new@example.com", role: "support", invited_by: admin)

    get "/dashboard/api/invitations/#{token}"
    expect(json_body).to include("email" => "new@example.com", "merchant_name" => admin.merchant.name)

    post "/dashboard/api/invitations/#{token}/accept",
         params: { name: "New", password: "a long enough password" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)

    get "/dashboard/api/otp/setup"
    expect(json_body["qr_svg"]).to include("<svg")

    post "/dashboard/api/otp/confirm", params: { code: ROTP::TOTP.new(user.reload.otp_secret).now }.to_json,
                                       headers: ui_headers
    expect(json_body["recovery_codes"].size).to eq(10)
    expect(user.reload).to have_attributes(otp_enabled?: true, invitation_digest: nil)

    get "/dashboard/api/me"
    expect(response).to have_http_status(:ok)
  end

  it "rejects a short password on acceptance" do
    _user, token = MerchantUser.invite!(merchant: admin.merchant, email: "short@example.com", role: "viewer", invited_by: admin)
    post "/dashboard/api/invitations/#{token}/accept", params: { name: "S", password: "short" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "cannot sign in with only a password before enrolling 2FA" do
    user, token = MerchantUser.invite!(merchant: admin.merchant, email: "half@example.com", role: "viewer", invited_by: admin)
    post "/dashboard/api/invitations/#{token}/accept", params: { name: "H", password: "a long enough password" }.to_json,
                                                       headers: ui_headers
    post "/dashboard/api/session", params: { email: user.email, password: "a long enough password" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an expired invitation" do
    _user, token = MerchantUser.invite!(merchant: admin.merchant, email: "late@example.com", role: "viewer", invited_by: admin)
    travel 11.days
    get "/dashboard/api/invitations/#{token}"
    expect(response).to have_http_status(:not_found)
  end
end
