require "rails_helper"

RSpec.describe "Rate limiting (Rack::Attack)", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key }
  let(:key) { merchant_and_key.last }

  before { Rack::Attack.cache.store.clear }

  it "returns 429 with Retry-After and the standard error shape once a merchant exceeds the limit" do
    stub_const("Rack::Attack::LIMIT_PER_MINUTE", 5) # the throttle reads it per request; unwinds after the example

    5.times do
      get "/v1/balance", headers: auth_headers(key)
      expect(response).to have_http_status(:ok)
    end

    get "/v1/balance", headers: auth_headers(key)

    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"].to_i).to be_between(1, 60)
    expect(json_body["error"]).to include("type" => "rate_limit", "code" => "rate_limited", "retriable" => true)
    expect(json_body["error"]["request_id"]).to be_present
  end

  it "keys on the merchant, so one merchant's burst does not throttle another" do
    stub_const("Rack::Attack::LIMIT_PER_MINUTE", 3)
    _other, other_key = create_merchant_with_key

    4.times { get "/v1/balance", headers: auth_headers(key) }
    expect(response).to have_http_status(:too_many_requests)

    get "/v1/balance", headers: auth_headers(other_key)
    expect(response).to have_http_status(:ok)
  end

  it "throttles sign-in attempts per IP across accounts" do
    # Each attempt runs a real bcrypt comparison (~0.25s), so 21 of them could
    # straddle a one-minute throttle window; frozen time keeps them in one.
    freeze_time do
      21.times do |i|
        post "/dashboard/api/session", params: { email: "user#{i}@example.com", password: "x" * 12 }.to_json,
                                       headers: { "Content-Type" => "application/json" }
      end
    end
    expect(response).to have_http_status(:too_many_requests)
  end
end
