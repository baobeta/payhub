# frozen_string_literal: true

require "rack/test"
require "rspec"
require_relative "../app"

RSpec.describe Nordpay::App do
  include Rack::Test::Methods

  def app = described_class

  let(:headers) { { "HTTP_AUTHORIZATION" => "Bearer np_test_key", "CONTENT_TYPE" => "application/json" } }
  let(:body) { { amount_minor: 2500, currency: "EUR", payment_method_token: "tok_visa" } }

  before do
    described_class.failure.merge!("timeout_rate" => 0, "flaky_500_rate" => 0, "duplicate_response_rate" => 0,
                                   "decline_rate" => 0, "timeout_seconds" => 0.05)
    post "/_sim/reset"
  end

  def charge!(ref, force: nil, **overrides)
    h = headers.merge("HTTP_X_REQUEST_ID" => ref)
    h["HTTP_X_SIM_FORCE"] = force if force
    post "/charges", JSON.generate(body.merge(overrides)), h
    last_response
  end

  it "authorizes a charge and is idempotent on X-Request-Id" do
    first = JSON.parse(charge!("ref_1").body)
    expect(last_response.status).to eq(200)
    expect(first).to include("reference" => "ref_1", "status" => "authorized", "amount_minor" => 2500)

    second = JSON.parse(charge!("ref_1", amount_minor: 9999).body) # different body, same id
    expect(second["id"]).to eq(first["id"])
    expect(second["amount_minor"]).to eq(2500) # original, untouched
  end

  it "rejects a missing api key, missing request id, bad currency" do
    post "/charges", JSON.generate(body), headers.merge("HTTP_X_REQUEST_ID" => "r")
    expect(last_response.status).to eq(200)
    post "/charges", JSON.generate(body), "HTTP_X_REQUEST_ID" => "r"
    expect(last_response.status).to eq(401)
    post "/charges", JSON.generate(body), headers
    expect(last_response.status).to eq(400)
    charge!("r2", currency: "VND")
    expect(last_response.status).to eq(422)
  end

  it "records the charge BEFORE hanging on a forced timeout, so a later GET finds it" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    charge!("ref_timeout", force: "timeout")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be >= 0.05

    get "/charges/ref_timeout", nil, headers
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["status"]).to eq("authorized")
  end

  it "returns 500 on the first attempt and 200 on the retry with the same reference" do
    charge!("ref_flaky", force: "flaky_500")
    expect(last_response.status).to eq(500)

    charge!("ref_flaky", force: "flaky_500")
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["status"]).to eq("authorized")
    expect(JSON.parse(get("/_sim/charges", nil, headers).body).size).to eq(1) # one charge, not two
  end

  it "returns the same charge twice in one body when forced to duplicate" do
    parsed = JSON.parse(charge!("ref_dup", force: "duplicate").body)
    expect(parsed["charges"].size).to eq(2)
    expect(parsed["charges"].map { |c| c["id"] }.uniq.size).to eq(1)
  end

  it "declines with HTTP 200 — transport success is not domain success" do
    parsed = JSON.parse(charge!("ref_decline", force: "decline").body)
    expect(last_response.status).to eq(200)
    expect(parsed).to include("status" => "declined", "code" => "insufficient_funds")
  end

  it "404s a reference it has never seen" do
    get "/charges/nope", nil, headers
    expect(last_response.status).to eq(404)
  end

  it "captures partially then fully" do
    charge!("ref_cap")
    post "/charges/ref_cap/capture", JSON.generate(amount_minor: 1000), headers
    expect(JSON.parse(last_response.body)).to include("status" => "authorized", "captured_minor" => 1000)
    post "/charges/ref_cap/capture", "{}", headers
    expect(JSON.parse(last_response.body)).to include("status" => "captured", "captured_minor" => 2500)
    post "/charges/ref_cap/capture", "{}", headers
    expect(last_response.status).to eq(409)
  end
end
