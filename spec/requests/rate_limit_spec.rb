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

  describe "per-merchant budgets (L6; Stripe: per account, live 100/s vs sandbox 25/s)" do
    let(:merchant) { merchant_and_key.first }

    it "defaults to 300/min live and 75/min test, Stripe's 4:1 ratio" do
      expect(Rack::Attack::LIMIT_PER_MINUTE).to eq(300)
      expect(Rack::Attack::TEST_LIMIT_PER_MINUTE).to eq(75)
    end

    it "TC-L6-1: two live keys of one merchant share one budget" do
      stub_const("Rack::Attack::LIMIT_PER_MINUTE", 4)
      _second, second_key = ApiKey.issue!(merchant:, livemode: true, name: "Second")

      2.times { get "/v1/balance", headers: auth_headers(key) }
      2.times do
        get "/v1/balance", headers: auth_headers(second_key)
        expect(response).to have_http_status(:ok)
      end

      get "/v1/balance", headers: auth_headers(second_key)
      expect(response).to have_http_status(:too_many_requests)
    end

    it "TC-L6-2: the test key's budget is separate and lower; live is unaffected" do
      stub_const("Rack::Attack::LIMIT_PER_MINUTE", 5)
      stub_const("Rack::Attack::TEST_LIMIT_PER_MINUTE", 3)
      _test_key, test_raw = ApiKey.issue!(merchant:, livemode: false, name: "Test")

      3.times do
        get "/v1/balance", headers: auth_headers(test_raw)
        expect(response).to have_http_status(:ok)
      end
      get "/v1/balance", headers: auth_headers(test_raw)
      expect(response).to have_http_status(:too_many_requests)

      get "/v1/balance", headers: auth_headers(key)
      expect(response).to have_http_status(:ok)
    end

    it "TC-L6-3: the 429 carries Retry-After and PayHub-Rate-Limited-Reason: global-rate" do
      stub_const("Rack::Attack::LIMIT_PER_MINUTE", 1)

      2.times { get "/v1/balance", headers: auth_headers(key) }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"].to_i).to be_between(1, 60)
      expect(response.headers["PayHub-Rate-Limited-Reason"]).to eq("global-rate")
      expect(json_body["error"]).to include("type" => "rate_limit", "code" => "rate_limited")
    end

    it "caches the key lookup by digest, never the raw key" do
      get "/v1/balance", headers: auth_headers(key)

      merchant_id, livemode = Rails.cache.read("#{Rack::Attack::KEY_CACHE_PREFIX}#{Merchant.digest(key)}")
      expect([merchant_id, livemode]).to eq([merchant_and_key.first.id, true])
      expect(Rails.cache.instance_variable_get(:@data).keys.join).not_to include(key)
    end

    it "an unknown key falls back to the unauthenticated per-IP throttle" do
      30.times { get "/v1/balance", headers: auth_headers("sk_live_#{SecureRandom.hex(24)}") }
      expect(response).to have_http_status(:unauthorized)

      get "/v1/balance", headers: auth_headers("sk_live_#{SecureRandom.hex(24)}")
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "dashboard and ops sessions (L6)" do
    it "TC-L6-4: a signed-in dashboard session above the limit gets 429; another merchant's session is unaffected" do
      stub_const("Rack::Attack::SESSION_LIMIT_PER_MINUTE", 3)
      sign_in_as(create(:merchant_user))

      3.times do
        get "/dashboard/api/me"
        expect(response).to have_http_status(:ok)
      end
      get "/dashboard/api/me"
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["PayHub-Rate-Limited-Reason"]).to eq("global-rate")

      sign_in_as(create(:merchant_user))
      get "/dashboard/api/me"
      expect(response).to have_http_status(:ok)
    end

    it "throttles an ops session the same way" do
      stub_const("Rack::Attack::SESSION_LIMIT_PER_MINUTE", 2)
      sign_in_operator(create(:operator))

      3.times { get "/ops/api/me" }
      expect(response).to have_http_status(:too_many_requests)
    end
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
