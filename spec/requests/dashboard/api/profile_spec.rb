# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard profile and mode", type: :request do
  let(:user) { create(:merchant_user, role: "viewer") }

  describe "PATCH /me/password" do
    let(:params) { { current_password: "correct horse battery staple", new_password: "an even better password" } }

    it "needs step-up" do
      sign_in_as(user)
      patch "/dashboard/api/me/password", params: params.to_json, headers: ui_headers
      expect(json_body.dig("error", "code")).to eq("step_up_required")
    end

    it "changes the password and signs out every other session" do
      other = Session.create!(principal: user, ip: "10.0.0.9", user_agent: "other")
      current = sign_in_as(user, stepped_up: true)
      patch "/dashboard/api/me/password", params: params.to_json, headers: ui_headers
      expect(response).to have_http_status(:no_content)
      expect(user.reload.authenticate("an even better password")).to be_truthy
      expect(other.reload.revoked_at).to be_present
      expect(current.reload.revoked_at).to be_nil
    end

    it "rejects a wrong current password" do
      sign_in_as(user, stepped_up: true)
      patch "/dashboard/api/me/password", params: params.merge(current_password: "nope").to_json, headers: ui_headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "regenerates recovery codes after step-up" do
    sign_in_as(user, stepped_up: true)
    post "/dashboard/api/me/recovery_codes", headers: ui_headers
    expect(json_body["recovery_codes"].size).to eq(10)
  end

  it "switches the session between live and test data" do
    sign_in_as(user)
    put "/dashboard/api/mode", params: { livemode: false }.to_json, headers: ui_headers
    expect(json_body["livemode"]).to be(false)
    get "/dashboard/api/me"
    expect(json_body["livemode"]).to be(false)
  end
end
