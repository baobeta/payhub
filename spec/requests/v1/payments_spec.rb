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
