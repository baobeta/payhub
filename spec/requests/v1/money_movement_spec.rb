require "rails_helper"

RSpec.describe "V1 capture / cancel / refunds / balance", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key }
  let(:merchant) { merchant_and_key.first }
  let(:key) { merchant_and_key.last }
  let(:adapter) { FakePspAdapter.new }

  before { allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter) }

  def authorized_payment
    create(:payment, merchant: merchant).tap do |p|
      p.transition!(:authorized, sort_key: p.created_at + 1.second, source: "worker")
    end
  end

  def captured_payment(amount = 2500)
    authorized_payment.tap do |p|
      Ledger.record_capture!(p, amount)
      p.update_column(:captured_minor, amount)
      p.transition!(:captured, sort_key: p.created_at + 2.seconds, source: "worker")
    end
  end

  def charge(status, payment, captured_minor: 0)
    PspAdapter::Result.new(
      status: PspAdapter::Result::Status.deserialize(status.to_s), psp_reference: payment.psp_reference,
      psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: payment.created_at + 5.seconds,
      raw: { "captured_minor" => captured_minor }
    )
  end

  describe "POST /v1/payments/:id/capture" do
    it "202s and enqueues a capture for the full authorized amount by default" do
      payment = authorized_payment

      expect do
        post "/v1/payments/#{payment.id}/capture", params: "{}", headers: auth_headers(key)
      end.to have_enqueued_job(CapturePaymentJob).with(payment.id, 2500)
      expect(response).to have_http_status(:accepted)
    end

    it "allows a partial capture and rejects one beyond the authorized amount" do
      payment = authorized_payment

      post "/v1/payments/#{payment.id}/capture", params: { amount_minor: 1000 }.to_json, headers: auth_headers(key)
      expect(response).to have_http_status(:accepted)

      post "/v1/payments/#{payment.id}/capture", params: { amount_minor: 9999 }.to_json, headers: auth_headers(key)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]["details"]).to have_key("amount_minor")
    end

    it "rejects capture of a pending payment with invalid_state" do
      payment = create(:payment, merchant: merchant)

      post "/v1/payments/#{payment.id}/capture", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_state")
    end
  end

  describe "POST /v1/payments/:id/cancel" do
    it "voids synchronously and returns the canceled payment with history" do
      payment = authorized_payment
      adapter.script(:cancel, charge(:canceled, payment))

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:ok)
      expect(json_body["state"]).to eq("canceled")
      expect(json_body["transitions"].last["to"]).to eq("canceled")
    end

    it "is only valid from authorized" do
      payment = captured_payment

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_state")
      expect(payment.reload.state).to eq("captured")
    end

    it "on timeout, fetches; if still authorized answers 503 retriable and leaves state untouched" do
      payment = authorized_payment
      adapter.script(:cancel, PspAdapter::TimedOut)
      adapter.script(:fetch, charge(:authorized, payment))

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:service_unavailable)
      expect(json_body["error"]["retriable"]).to be true
      expect(payment.reload.state).to eq("authorized")
    end
  end

  describe "POST /v1/payments/:id/refunds" do
    it "202s a pending refund, reserves the amount, and enqueues the PSP call" do
      payment = captured_payment

      expect do
        post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 500, reason: "damaged" }.to_json,
                                                    headers: auth_headers(key)
      end.to have_enqueued_job(RefundPaymentJob)

      expect(response).to have_http_status(:accepted)
      expect(json_body).to include("state" => "pending", "amount_minor" => 500, "reason" => "damaged")
      expect(json_body["psp_reference"]).to start_with("phr_")
    end

    it "counts pending refunds as reserved, so two partials cannot together exceed the capture" do
      payment = captured_payment(2500)

      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 2000 }.to_json, headers: auth_headers(key)
      expect(response).to have_http_status(:accepted)

      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 1000 }.to_json, headers: auth_headers(key)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]["details"]["amount_minor"].first).to include("pending 2000")
    end

    it "rejects a refund of an authorized-but-uncaptured payment" do
      payment = authorized_payment

      post "/v1/payments/#{payment.id}/refunds", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_state")
    end

    it "rejects a partial refund when the adapter only supports full refunds (Kiripay semantics)" do
      payment = captured_payment
      allow(PspRouter).to receive(:adapter).with("nordpay").and_return(FakePspAdapter.new(partial_refund: false))

      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 500 }.to_json, headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("partial_refund_unsupported")
    end
  end

  describe "GET /v1/balance" do
    it "derives per-currency balances from the ledger" do
      captured_payment(2500)
      vnd = create(:payment, :vnd, merchant: merchant)
      Ledger.record_capture!(vnd, 500_000)

      get "/v1/balance", headers: auth_headers(key)

      expect(response).to have_http_status(:ok)
      expect(json_body["available"]).to contain_exactly(
        { "currency" => "EUR", "amount_minor" => 2500, "display_amount" => "25.00" },
        { "currency" => "VND", "amount_minor" => 500_000, "display_amount" => "500000" }
      )
      expect(json_body["pending"]).to eq([])
    end

    it "moves a requested refund from available to pending until the PSP confirms it" do
      payment = captured_payment(2500)
      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 500 }.to_json, headers: auth_headers(key)

      get "/v1/balance", headers: auth_headers(key)

      expect(json_body["available"]).to eq([{ "currency" => "EUR", "amount_minor" => 2000, "display_amount" => "20.00" }])
      expect(json_body["pending"]).to eq([{ "currency" => "EUR", "amount_minor" => 500, "display_amount" => "5.00" }])
    end
  end
end
