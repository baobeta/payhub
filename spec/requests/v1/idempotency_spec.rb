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
end
