# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard sign-in", type: :request do
  let!(:user) { create(:merchant_user, email: "sam@example.com") }
  let(:password) { "correct horse battery staple" }

  def code = ROTP::TOTP.new(user.reload.otp_secret).now

  def sign_in_password(pw = password, email: "sam@example.com")
    post "/dashboard/api/session", params: { email:, password: pw }.to_json, headers: ui_headers
  end

  it "needs password, then code, then gives a session" do
    sign_in_password
    expect(json_body).to eq("otp_required" => true)

    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized) # password alone is not a session

    post "/dashboard/api/session/otp", params: { code: }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
    get "/dashboard/api/me"
    expect(response).to have_http_status(:ok)
  end

  it "rejects a code without a password step first" do
    post "/dashboard/api/session/otp", params: { code: }.to_json, headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
    expect(json_body.dig("error", "code")).to eq("password_step_required")
  end

  it "answers the same for an unknown email and a wrong password" do
    sign_in_password(email: "nobody@example.com")
    unknown = [response.status, json_body.dig("error", "code")]
    sign_in_password("wrong-password-123")
    expect([response.status, json_body.dig("error", "code")]).to eq(unknown)
  end

  it "locks with 423 after 10 failures, counting wrong codes too" do
    sign_in_password
    10.times { post "/dashboard/api/session/otp", params: { code: "000000" }.to_json, headers: ui_headers }
    sign_in_password
    expect(response).to have_http_status(423)
    expect(json_body.dig("error", "details", "locked_until")).to be_present
  end

  it "signs in with a recovery code, once" do
    codes = RecoveryCode.regenerate!(user)
    sign_in_password
    post "/dashboard/api/session/recovery", params: { code: codes.first }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
  end

  it "steps up with a fresh code and records it" do
    session = sign_in_as(user)
    post "/dashboard/api/session/step_up", params: { code: }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(session.reload.stepped_up_at).to be_present
  end

  it "signs out and revokes the session row" do
    session = sign_in_as(user)
    delete "/dashboard/api/session", headers: ui_headers
    expect(response).to have_http_status(:no_content)
    expect(session.reload.revoked_at).to be_present
  end

  it "audits sign-in and emails on a new device" do
    Session.create!(principal: user, ip: "10.9.9.9", user_agent: "old browser") # has signed in before
    sign_in_password
    expect do
      post "/dashboard/api/session/otp", params: { code: }.to_json, headers: ui_headers
    end.to change(AuditEvent.where(action: "session.created"), :count).by(1)
       .and have_enqueued_mail(SecurityMailer, :new_sign_in)
  end

  it "does not email on a first ever sign-in" do
    sign_in_password
    expect do
      post "/dashboard/api/session/otp", params: { code: }.to_json, headers: ui_headers
    end.not_to have_enqueued_mail(SecurityMailer, :new_sign_in)
  end

  it "refuses a write without the CSRF token" do
    ActionController::Base.allow_forgery_protection = true
    sign_in_as(user)
    delete "/dashboard/api/session", headers: ui_headers
    expect(response).to have_http_status(:forbidden)
    expect(json_body.dig("error", "code")).to eq("invalid_csrf_token")
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
