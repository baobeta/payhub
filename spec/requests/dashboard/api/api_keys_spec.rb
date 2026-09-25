# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard API keys", type: :request do
  let(:merchant) { create(:merchant) }
  let(:developer) { create(:merchant_user, merchant:, role: "developer") }

  def create_key(name: "Server")
    post "/dashboard/api/api_keys", params: { name:, note: "k8s secret" }.to_json, headers: ui_headers
  end

  it "creates a key after step-up, shows the secret once, and never lists it" do
    sign_in_as(developer, stepped_up: true)
    create_key
    expect(response).to have_http_status(:created)
    secret = json_body["secret"]
    expect(secret).to start_with("sk_live_")

    get "/dashboard/api/api_keys"
    expect(response.body).not_to include(secret)
    expect(json_body["data"].first).to include("name" => "Server", "status" => "active", "created_by" => developer.email)
    expect(AuditEvent.last.action).to eq("api_key.created")
  end

  it "needs step-up to create" do
    sign_in_as(developer)
    create_key
    expect(json_body.dig("error", "code")).to eq("step_up_required")
  end

  it "is forbidden to support" do
    sign_in_as(create(:merchant_user, merchant:, role: "support"), stepped_up: true)
    get "/dashboard/api/api_keys"
    expect(response).to have_http_status(:forbidden)
  end

  it "rolls with a 24h overlap: both keys work on /v1" do
    key, old_raw = ApiKey.issue!(merchant:, livemode: true, name: "Server")
    sign_in_as(developer, stepped_up: true)
    post "/dashboard/api/api_keys/#{key.id}/roll", params: { expires_in: "24h" }.to_json, headers: ui_headers
    new_raw = json_body["secret"]

    [old_raw, new_raw].each do |raw|
      get "/v1/balance", headers: auth_headers(raw)
      expect(response).to have_http_status(:ok)
    end
  end

  it "rejects an unknown overlap" do
    key, = ApiKey.issue!(merchant:, livemode: true, name: "Server")
    sign_in_as(developer, stepped_up: true)
    post "/dashboard/api/api_keys/#{key.id}/roll", params: { expires_in: "forever" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "revokes at once" do
    key, raw = ApiKey.issue!(merchant:, livemode: true, name: "Server")
    sign_in_as(developer, stepped_up: true)
    post "/dashboard/api/api_keys/#{key.id}/revoke", headers: ui_headers
    get "/v1/balance", headers: auth_headers(raw)
    expect(response).to have_http_status(:unauthorized)
  end

  it "issues and lists test keys in test mode" do
    ApiKey.issue!(merchant:, livemode: true, name: "Live one")
    sign_in_as(developer, livemode: false, stepped_up: true)
    create_key(name: "Test one")
    expect(json_body["secret"]).to start_with("sk_test_")
    get "/dashboard/api/api_keys"
    expect(json_body["data"].pluck("name")).to eq(["Test one"])
  end

  it "cannot roll another merchant's key" do
    other_key, = ApiKey.issue!(merchant: create(:merchant), livemode: true, name: "Theirs")
    sign_in_as(developer, stepped_up: true)
    post "/dashboard/api/api_keys/#{other_key.id}/roll", params: { expires_in: "now" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:not_found)
  end
end
