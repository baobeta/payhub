# frozen_string_literal: true

require "rack/test"
require "rspec"
require_relative "../app"

RSpec.describe Kiripay::App do
  include Rack::Test::Methods

  def app = described_class

  let(:headers) { { "HTTP_AUTHORIZATION" => "Bearer kp_test_key", "CONTENT_TYPE" => "application/json" } }
  let(:body) { { amount: "500000", currency: "VND", wallet_token: "wal_x", merchant_reference: "ph_1" } }

  before do
    described_class.deliver_webhooks = false # inspect store.sent_webhooks instead of hitting the network
    described_class.failure.merge!("timeout_rate" => 0, "timeout_seconds" => 0.05, "webhook_duplicate_rate" => 0,
                                   "webhook_out_of_order_rate" => 0, "webhook_late_rate" => 0, "webhook_never_rate" => 0,
                                   "webhook_bad_signature_rate" => 0, "decline_rate" => 0)
    post "/_sim/reset"
  end

  def charge!(**overrides)
    post "/charges", JSON.generate(body.merge(overrides)), headers
    JSON.parse(last_response.body)
  end

  def approve!(id, force: "")
    post "/_sim/charges/#{id}/approve", JSON.generate(force: force), headers
    JSON.parse(last_response.body)
  end

  def webhooks = JSON.parse(get("/_sim/webhooks", nil, headers).body)

  it "creates a pending_redirect charge with a redirect_url and NO authorize step" do
    c = charge!
    expect(last_response.status).to eq(200)
    expect(c).to include("status" => "pending_redirect", "amount" => "500000", "currency" => "VND")
    expect(c["redirect_url"]).to end_with("/pay/#{c['id']}")
  end

  it "has no idempotency: the same merchant_reference twice creates TWO charges" do
    a = charge!
    b = charge!
    expect(a["id"]).not_to eq(b["id"])

    get "/charges", { merchant_reference: "ph_1" }, headers
    expect(JSON.parse(last_response.body)["data"].size).to eq(2)
  end

  it "rejects VND with a decimal point and non-SEA currencies" do
    charge!(amount: "500.50")
    expect(last_response.status).to eq(422)
    charge!(currency: "EUR", amount: "25.00")
    expect(last_response.status).to eq(422)
  end

  it "records the charge before hanging on a forced timeout" do
    post "/charges", JSON.generate(body), headers.merge("HTTP_X_SIM_FORCE" => "timeout")
    get "/charges", { merchant_reference: "ph_1" }, headers
    expect(JSON.parse(last_response.body)["data"].size).to eq(1)
  end

  it "on approval, captures and emits charge.created then charge.captured, signed" do
    c = charge!
    approve!(c["id"])

    expect(JSON.parse(get("/charges/#{c['id']}", nil, headers).body)["status"]).to eq("captured")
    sent = webhooks
    expect(sent.map { |w| w["event"]["type"] }).to eq(%w[charge.created charge.captured])
    expect(sent.first["headers"]["X-Kiripay-Signature"]).to match(/\At=\d+,v1=[0-9a-f]{64}\z/)
    expect(Time.parse(sent[0]["event"]["created_at"])).to be <= Time.parse(sent[1]["event"]["created_at"])
  end

  it "misbehaves on demand: duplicate ×5, out of order, bad signature, never" do
    c = charge!
    approve!(c["id"], force: "webhook_duplicate")
    expect(webhooks.count { |w| w["event"]["type"] == "charge.captured" }).to eq(5)

    post "/_sim/reset"
    c = charge!
    approve!(c["id"], force: "webhook_out_of_order")
    expect(webhooks.map { |w| w["event"]["type"] }).to eq(%w[charge.captured charge.created])

    post "/_sim/reset"
    c = charge!
    approve!(c["id"], force: "webhook_bad_signature")
    good = "t=1,v1=#{OpenSSL::HMAC.hexdigest('SHA256', 'kp_whsec_test', "1.#{JSON.generate(webhooks.first['event'])}")}"
    expect(webhooks.first["headers"]["X-Kiripay-Signature"]).not_to eq(good)

    post "/_sim/reset"
    c = charge!
    approve!(c["id"], force: "webhook_never")
    expect(webhooks).to be_empty
    expect(JSON.parse(get("/charges/#{c['id']}", nil, headers).body)["status"]).to eq("captured") # it DID capture
  end

  it "declines at approval time with a charge.declined webhook" do
    c = charge!
    approve!(c["id"], force: "decline")
    expect(webhooks.map { |w| w["event"]["type"] }).to eq(%w[charge.declined])
  end

  it "refunds in full only, once" do
    c = charge!
    approve!(c["id"])

    post "/charges/#{c['id']}/refunds", JSON.generate(amount: "100000"), headers
    expect(last_response.status).to eq(422)
    post "/charges/#{c['id']}/refunds", "{}", headers
    expect(JSON.parse(last_response.body)).to include("status" => "succeeded", "amount" => "500000")
    post "/charges/#{c['id']}/refunds", "{}", headers
    expect(last_response.status).to eq(409)
  end
end
