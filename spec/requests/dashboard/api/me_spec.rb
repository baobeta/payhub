# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /dashboard/api/me", type: :request do
  let(:user) { create(:merchant_user, role: "support") }

  it "401s without a session" do
    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the user, the live merchant, the mode and the role's permissions" do
    sign_in_as(user)
    get "/dashboard/api/me"
    body = json_body
    expect(body.dig("user", "email")).to eq(user.email)
    expect(body["livemode"]).to be(true)
    expect(body["permissions"]).to match_array(Permissions.for(:merchant, "support").to_a)
  end

  it "401s once the session has been idle for 15 minutes" do
    sign_in_as(user)
    travel 16.minutes
    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "401s for a disabled user even with a live session" do
    sign_in_as(user)
    user.update!(disabled_at: Time.current)
    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "reflects a role change on the very next request" do
    sign_in_as(user)
    user.update!(role: "viewer")
    get "/dashboard/api/me"
    expect(json_body["permissions"]).not_to include("payments.refund")
  end

  it "answers an unknown API path with JSON 404, not the HTML shell" do
    get "/dashboard/api/nope"
    expect(response).to have_http_status(:not_found)
    expect(json_body.dig("error", "code")).to eq("not_found")
  end
end
