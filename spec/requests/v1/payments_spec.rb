require "rails_helper"

RSpec.describe "V1 payments", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key }
  let(:merchant) { merchant_and_key.first }
  let(:key) { merchant_and_key.last }
  let(:valid_body) { { amount_minor: 2500, currency: "EUR", payment_method_token: "tok_visa" } }

  describe "POST /v1/payments" do
    it "returns 202 pending, enqueues the PSP call, and never hits the network" do
      expect do
        post "/v1/payments", params: valid_body.to_json, headers: auth_headers(key)
      end.to have_enqueued_job(AuthorizePaymentJob)

      expect(response).to have_http_status(:accepted)
      expect(json_body).to include("state" => "pending", "amount_minor" => 2500, "currency" => "EUR",
                                   "psp_name" => "nordpay", "display_amount" => "25.00")
      expect(a_request(:any, /nordpay/)).not_to have_been_made
    end

    it "reserves a psp_reference before any PSP call and records ownership" do
      post "/v1/payments", params: valid_body.to_json, headers: auth_headers(key)

      payment = Payment.find(json_body["id"])
      expect(payment.psp_reference).to start_with("ph_")
      expect(payment.merchant).to eq(merchant)
      expect(payment.fx_rate).to eq(1) # EUR → EUR
    end

    it "snapshots the FX rate onto the payment for a cross-currency payment" do
      create(:fx_rate, base: "GBP", quote: "EUR", rate: BigDecimal("1.17"))

      post "/v1/payments", params: valid_body.merge(currency: "GBP").to_json, headers: auth_headers(key)

      expect(response).to have_http_status(:accepted)
      expect(json_body["fx_rate"]).to eq("1.17")
      expect(json_body["merchant_currency"]).to eq("EUR")
    end

    it "returns 503 api_error (retriable) when a supported currency has no FX rate — never a raw 500" do
      post "/v1/payments", params: valid_body.merge(currency: "THB").to_json, headers: auth_headers(key)

      expect(response).to have_http_status(:service_unavailable)
      expect(json_body["error"]).to include("type" => "api_error", "code" => "currency_unavailable",
                                            "retriable" => true, "param" => "currency")
      expect(Payment.count).to eq(0)
    end

    it "TC-A2-1: VND, THB and IDR payments are routed to kiripay" do
      create(:fx_rate, base: "VND", quote: "EUR", rate: BigDecimal("0.000037"))
      create(:fx_rate, base: "THB", quote: "EUR", rate: BigDecimal("0.026"))
      create(:fx_rate, base: "IDR", quote: "EUR", rate: BigDecimal("0.000059"))

      [
        { currency: "VND", amount_minor: 50_000 },
        { currency: "THB", amount_minor: 100 },
        { currency: "IDR", amount_minor: 100_000 }
      ].each do |params|
        post "/v1/payments", params: { payment_method_token: "tok_visa" }.merge(params).to_json,
                             headers: auth_headers(key)
        expect(response).to have_http_status(:accepted), "expected 202 for #{params[:currency]}: #{response.body}"
        expect(json_body["psp_name"]).to eq("kiripay"), "expected kiripay for #{params[:currency]}"
      end
    end

    it "TC-A1-2: GBP and USD payments are routed to nordpay" do
      create(:fx_rate, base: "GBP", quote: "EUR", rate: BigDecimal("1.17"))
      create(:fx_rate, base: "USD", quote: "EUR", rate: BigDecimal("0.93"))

      [
        { currency: "GBP", amount_minor: 2500 },
        { currency: "USD", amount_minor: 2500 }
      ].each do |params|
        post "/v1/payments", params: { payment_method_token: "tok_visa" }.merge(params).to_json,
                             headers: auth_headers(key)
        expect(response).to have_http_status(:accepted), "expected 202 for #{params[:currency]}: #{response.body}"
        expect(json_body["psp_name"]).to eq("nordpay"), "expected nordpay for #{params[:currency]}"
      end
    end

    # A validation 422 keeps no request ticket (TC-A4-2, DECISIONS #3).
    it "TC-A4-1: invalid amounts (0, float, string, nil) get 422, create no payment, and keep no key" do
      [0, 25.5, "2500", nil].each do |amount|
        idem = "bad-amount-#{SecureRandom.uuid}"
        post "/v1/payments",
             params: { amount_minor: amount, currency: "EUR", payment_method_token: "tok_visa" }.to_json,
             headers: auth_headers(key, idempotency_key: idem)
        expect(response).to have_http_status(:unprocessable_content),
                             "expected 422 for amount=#{amount.inspect}: #{response.body}"
        expect(json_body["error"]["details"]).to have_key("amount_minor")
        expect(IdempotencyKey.find_by(key: idem)).to be_nil
      end
      expect(Payment.count).to eq(0)
    end

    it "TC-A5-1: a VND payment stores amount_minor as-is and the PSP body carries the integer string" do
      create(:fx_rate, base: "VND", quote: "EUR", rate: BigDecimal("0.000037"))
      kiripay = FakePspAdapter.new(name: "kiripay", currencies: %w[VND THB IDR])
      allow(PspRouter).to receive(:adapter).with("kiripay").and_return(kiripay)

      post "/v1/payments",
           params: { amount_minor: 50_000, currency: "VND", payment_method_token: "tok_wallet" }.to_json,
           headers: auth_headers(key)
      expect(response).to have_http_status(:accepted)

      payment = Payment.find(json_body["id"])
      expect(payment.amount_minor).to eq(50_000)

      # Run the authorize job to verify the PSP call carries "50000"
      kiripay.script(:authorize, PspAdapter::Result.new(
        status: PspAdapter::Result::Status::Authorized,
        psp_reference: payment.psp_reference, psp_charge_id: "kp_1",
        decline_code: nil, psp_timestamp: Time.current, raw: {}
      ))
      AuthorizePaymentJob.perform_now(payment.id)
      call_arg = kiripay.calls[:authorize].first
      expect(call_arg).to be_a(Payment)
      expect(call_arg.amount_minor).to eq(50_000)
    end

    it "TC-A7-1: FX rate is snapshotted at creation time; a newer rate doesn't change the payment" do
      create(:fx_rate, base: "GBP", quote: "EUR", rate: BigDecimal("1.17"), captured_at: 1.hour.ago)

      post "/v1/payments", params: { amount_minor: 2500, currency: "GBP", payment_method_token: "tok_visa" }.to_json,
                           headers: auth_headers(key)
      expect(response).to have_http_status(:accepted)

      payment = Payment.find(json_body["id"])
      original_rate = payment.fx_rate
      # Insert a newer rate
      create(:fx_rate, base: "GBP", quote: "EUR", rate: BigDecimal("1.25"), captured_at: Time.current)

      payment.reload
      expect(payment.fx_rate).to eq(original_rate)
    end

    it "returns 401 in the standard error shape without a valid key" do
      post "/v1/payments", params: valid_body.to_json, headers: auth_headers("sk_live_wrong")

      expect(response).to have_http_status(:unauthorized)
      expect(json_body["error"]).to include("type" => "invalid_request", "code" => "unauthorized", "retriable" => false)
      expect(json_body["error"]["request_id"]).to be_present
    end

    it "returns 400 without an Idempotency-Key header" do
      post "/v1/payments", params: valid_body.to_json, headers: auth_headers(key).except("Idempotency-Key")

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]).to include("code" => "missing_idempotency_key", "param" => "Idempotency-Key")
    end

    it "returns 422 with EVERY failing field, not just the first" do
      post "/v1/payments", params: { amount_minor: -5, currency: "XXX", capture: "yes" }.to_json,
                           headers: auth_headers(key)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]["details"].keys).to match_array(%w[amount_minor currency payment_method_token capture])
      expect(Payment.count).to eq(0)
    end
  end

  describe "GET /v1/payments/:id" do
    it "returns the payment with its transition history" do
      payment = create(:payment, merchant: merchant)
      payment.transition!(:authorized, sort_key: payment.created_at + 1, source: "worker", metadata: { "psp_charge_id" => "ch_1" })

      get "/v1/payments/#{payment.id}", headers: auth_headers(key)

      expect(response).to have_http_status(:ok)
      expect(json_body["state"]).to eq("authorized")
      expect(json_body["transitions"].map { |t| t["to"] }).to eq(%w[pending authorized])
      expect(json_body["transitions"].last["metadata"]).to eq("psp_charge_id" => "ch_1")
    end

    it "404s another merchant's payment — ids are not a capability" do
      other = create(:payment)

      get "/v1/payments/#{other.id}", headers: auth_headers(key)

      expect(response).to have_http_status(:not_found)
    end
  end
end
