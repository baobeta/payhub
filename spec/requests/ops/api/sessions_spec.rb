# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops sign-in", type: :request do
  let!(:operator) { create(:operator, email: "ops@example.com") }
  let(:password) { "correct horse battery staple" }

  def code = ROTP::TOTP.new(operator.reload.otp_secret).now

  def sign_in_password(pw = password, email: "ops@example.com")
    post "/ops/api/session", params: { email:, password: pw }.to_json, headers: ui_headers
  end

  it "needs password, then code, then gives an ops session" do
    sign_in_password
    expect(json_body).to eq("otp_required" => true)

    get "/ops/api/me"
    expect(response).to have_http_status(:unauthorized) # password alone is not a session

    post "/ops/api/session/otp", params: { code: }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("user", "role")).to eq("support")
    get "/ops/api/me"
    expect(response).to have_http_status(:ok)
  end

  it "does not accept a merchant session cookie" do
    sign_in_as(create(:merchant_user))
    get "/ops/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "does not accept a merchant email and password" do
    create(:merchant_user, email: "merchant@example.com")
    post "/ops/api/session", params: { email: "merchant@example.com", password: }.to_json, headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
    expect(json_body.dig("error", "code")).to eq("invalid_credentials")
  end

  it "locks with 423 after 10 failures, counting wrong codes too" do
    sign_in_password
    10.times { post "/ops/api/session/otp", params: { code: "000000" }.to_json, headers: ui_headers }
    sign_in_password
    expect(response).to have_http_status(423)
    expect(json_body.dig("error", "details", "locked_until")).to be_present
  end

  it "idles out after 10 minutes" do
    session = sign_in_operator(operator)
    session.update_columns(last_active_at: 11.minutes.ago)
    get "/ops/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "lets an admin invite an operator, who then enrols" do
    admin = create(:operator, role: "admin")
    sign_in_operator(admin, stepped_up: true)
    expect do
      post "/ops/api/invitations", params: { email: "newop@example.com", role: "ops" }.to_json, headers: ui_headers
    end.to change(Operator, :count).by(1).and have_enqueued_mail(OperatorMailer, :invite)
    expect(response).to have_http_status(:created)
  end

  it "shows an operator invitation from its token" do
    _, token = Operator.invite!(email: "fresh@example.com", role: "ops", invited_by: nil)
    get "/ops/api/invitations/#{token}"
    expect(json_body).to eq("email" => "fresh@example.com", "role" => "ops")
  end

  it "accepts an invitation and enrols the operator" do
    invited, token = Operator.invite!(email: "fresh@example.com", role: "ops", invited_by: nil)

    post "/ops/api/invitations/#{token}/accept",
         params: { name: "Fresh", password: }.to_json, headers: ui_headers
    expect(json_body).to eq("next" => "enrol_otp")

    get "/ops/api/otp/setup"
    expect(json_body["provisioning_uri"]).to include("otpauth://")

    post "/ops/api/otp/confirm", params: { code: ROTP::TOTP.new(invited.reload.otp_secret).now }.to_json,
                                 headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(json_body["recovery_codes"].length).to eq(10)

    get "/ops/api/me"
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("user", "email")).to eq("fresh@example.com")
  end

  it "signs out and revokes the session row" do
    session = sign_in_operator(operator)
    delete "/ops/api/session", headers: ui_headers
    expect(response).to have_http_status(:no_content)
    expect(session.reload.revoked_at).to be_present
  end
end
