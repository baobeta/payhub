# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Test mode separation", type: :request do
  let!(:live) { create_merchant_with_key }
  let(:merchant) { live.first }
  let(:live_key) { live.last }
  let(:test_key) { ApiKey.issue!(merchant:, livemode: false, name: "Test").last }

  it "authenticates a test key as the test twin" do
    expect(Merchant.authenticate(test_key)).to eq(merchant.test_twin!)
  end

  it "never shows test payments to a live key" do
    post "/v1/payments", headers: auth_headers(test_key),
                         params: { amount_minor: 2500, currency: "EUR", payment_method_token: "tok_visa" }.to_json
    expect(response).to have_http_status(:accepted)

    get "/v1/payments", headers: auth_headers(live_key)
    expect(json_body.fetch("data")).to be_empty

    get "/v1/payments", headers: auth_headers(test_key)
    expect(json_body.fetch("data").size).to eq(1)
  end

  describe "TC-L5-1 balances are separated by mode" do
    before do
      Ledger.record_capture!(create(:payment, merchant:, state: "captured", amount_minor: 2500), 2500)
      Ledger.record_capture!(create(:payment, merchant: merchant.test_twin!, state: "captured", amount_minor: 700), 700)
    end

    def available(key)
      get "/v1/balance", headers: auth_headers(key)
      json_body.fetch("available").to_h { |a| [a["currency"], a["amount_minor"]] }
    end

    it "TC-L5-1 a live key sees only the live ledger" do
      expect(available(live_key)).to eq("EUR" => 2500)
    end

    it "TC-L5-1 a test key sees only the test twin's ledger" do
      expect(available(test_key)).to eq("EUR" => 700)
    end
  end
end
