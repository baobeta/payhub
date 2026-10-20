require "rails_helper"

RSpec.describe "V1 idempotency", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key }
  let(:key) { merchant_and_key.last }
  let(:body) { { amount_minor: 2500, currency: "EUR", payment_method_token: "tok_visa" } }
  let(:idem) { "idem-#{SecureRandom.hex(4)}" }

  def create_payment(payload = body, idempotency_key: idem)
    post "/v1/payments", params: payload.to_json, headers: auth_headers(key, idempotency_key: idempotency_key)
  end

  it "replays the original 202 status and body with Idempotent-Replayed: true, creating one payment" do
    create_payment
    first = json_body
    expect(response).to have_http_status(:accepted)
    expect(response.headers["Idempotent-Replayed"]).to be_nil

    create_payment
    expect(response).to have_http_status(:accepted)
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
    expect(json_body).to eq(first)
    expect(Payment.count).to eq(1)
  end

  it "replays a 422 validation error too — a bad request is a repeatable answer" do
    create_payment({ amount_minor: -1 })
    expect(response).to have_http_status(:unprocessable_content)

    create_payment({ amount_minor: -1 })
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
  end

  it "returns 422 idempotency_error when the same key is sent with a different body" do
    create_payment
    create_payment(body.merge(amount_minor: 9000))

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body["error"]).to include("type" => "idempotency_error", "code" => "idempotency_key_reused",
                                          "retriable" => false)
    expect(Payment.count).to eq(1)
  end

  it "does not apply to GET" do
    payment = create(:payment, merchant: merchant_and_key.first)
    get "/v1/payments/#{payment.id}", headers: auth_headers(key).except("Idempotency-Key")
    expect(response).to have_http_status(:ok)
  end

  it "TC-A11-1: same key used by two different merchants creates two payments" do
    merchant2, key2 = create_merchant_with_key
    shared_key = "shared-key-#{SecureRandom.hex(4)}"

    post "/v1/payments", params: body.to_json, headers: auth_headers(key, idempotency_key: shared_key)
    expect(response).to have_http_status(:accepted)

    post "/v1/payments", params: body.to_json, headers: auth_headers(key2, idempotency_key: shared_key)
    expect(response).to have_http_status(:accepted)

    expect(Payment.count).to eq(2)
  end

  it "TC-A12-1: replay within 24h; new payment after 24h" do
    create_payment(body, idempotency_key: idem)
    first_id = json_body["id"]

    travel_to(23.hours.from_now) do
      create_payment(body, idempotency_key: idem)
      expect(response.headers["Idempotent-Replayed"]).to eq("true")
      expect(json_body["id"]).to eq(first_id)
      expect(Payment.count).to eq(1)
    end

    travel_to(25.hours.from_now) do
      create_payment(body, idempotency_key: idem)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
      expect(json_body["id"]).not_to eq(first_id)
      expect(Payment.count).to eq(2)
    end
  end

  it "TC-E9-1: capture / refund / cancel replay on v1 — second response is replayed" do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    merchant = merchant_and_key.first
    adapter = FakePspAdapter.new
    allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter)

    # Create an authorized payment for capture/cancel
    payment = create(:payment, merchant: merchant)
    payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")

    # Capture replay
    cap_key = "cap-#{SecureRandom.hex(4)}"
    post "/v1/payments/#{payment.id}/capture", params: "{}", headers: auth_headers(key, idempotency_key: cap_key)
    expect(response).to have_http_status(:accepted)
    first_cap = json_body

    post "/v1/payments/#{payment.id}/capture", params: "{}", headers: auth_headers(key, idempotency_key: cap_key)
    expect(response).to have_http_status(:accepted)
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
    expect(json_body).to eq(first_cap)
    expect(payment.captures.count).to eq(1)

    # Build a captured payment for refund
    cap_payment = create(:payment, merchant: merchant)
    Ledger.record_capture!(cap_payment, 2500)
    cap_payment.update_column(:captured_minor, 2500)
    cap_payment.transition!(:authorized, sort_key: cap_payment.created_at + 1.second, source: "worker")
    cap_payment.transition!(:captured, sort_key: cap_payment.created_at + 2.seconds, source: "worker")

    ref_key = "ref-#{SecureRandom.hex(4)}"
    post "/v1/payments/#{cap_payment.id}/refunds",
         params: { amount_minor: 500 }.to_json,
         headers: auth_headers(key, idempotency_key: ref_key)
    expect(response).to have_http_status(:accepted)
    first_ref = json_body

    post "/v1/payments/#{cap_payment.id}/refunds",
         params: { amount_minor: 500 }.to_json,
         headers: auth_headers(key, idempotency_key: ref_key)
    expect(response).to have_http_status(:accepted)
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
    expect(json_body).to eq(first_ref)
    expect(cap_payment.refunds.count).to eq(1)

    # Cancel replay
    auth_payment = create(:payment, merchant: merchant)
    auth_payment.transition!(:authorized, sort_key: auth_payment.created_at + 1.second, source: "worker")
    adapter.script(:cancel,
                   PspAdapter::Result.new(
                     status: PspAdapter::Result::Status::Canceled,
                     psp_reference: auth_payment.psp_reference,
                     psp_charge_id: "ch_1", decline_code: nil,
                     psp_timestamp: auth_payment.created_at + 5.seconds, raw: {}
                   ))

    cancel_key = "cancel-#{SecureRandom.hex(4)}"
    post "/v1/payments/#{auth_payment.id}/cancel", params: "{}", headers: auth_headers(key, idempotency_key: cancel_key)
    expect(response).to have_http_status(:ok)
    first_cancel = json_body

    post "/v1/payments/#{auth_payment.id}/cancel", params: "{}", headers: auth_headers(key, idempotency_key: cancel_key)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
    expect(json_body).to eq(first_cancel)
    expect(auth_payment.transitions.where(to_state: "canceled").count).to eq(1)
  end
end
