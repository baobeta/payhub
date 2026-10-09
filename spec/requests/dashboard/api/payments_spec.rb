# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard payments", type: :request do
  let(:merchant) { create(:merchant) }
  let(:support) { create(:merchant_user, merchant:, role: "support") }
  let(:viewer) { create(:merchant_user, merchant:, role: "viewer") }

  it "lists only the current merchant's payments, in the session's mode" do
    mine = create(:payment, merchant:)
    create(:payment) # another merchant's
    twin_payment = create(:payment, merchant: merchant.test_twin!)

    sign_in_as(viewer)
    get "/dashboard/api/payments"
    expect(json_body["data"].pluck("id")).to eq([mine.id])

    put "/dashboard/api/mode", params: { livemode: false }.to_json, headers: ui_headers
    get "/dashboard/api/payments"
    expect(json_body["data"].pluck("id")).to eq([twin_payment.id])
  end

  it "filters by state" do
    create(:payment, merchant:, state: "unknown")
    create(:payment, merchant:, state: "authorized")
    sign_in_as(viewer)
    get "/dashboard/api/payments", params: { state: "unknown" }
    expect(json_body["data"].pluck("state")).to eq(["unknown"])
  end

  it "404s another merchant's payment rather than 403, so ids are not confirmed" do
    sign_in_as(viewer)
    get "/dashboard/api/payments/#{create(:payment).id}"
    expect(response).to have_http_status(:not_found)
  end

  it "returns the timeline and can flags for the viewer's role" do
    payment = create(:payment, merchant:, state: "authorized")
    sign_in_as(viewer)
    get "/dashboard/api/payments/#{payment.id}"
    expect(json_body).to include("timeline", "can")
    expect(json_body["can"]).to include("capture" => false, "cancel" => false)
  end

  it "shows support the actions its role and the state allow" do
    payment = create(:payment, merchant:, state: "authorized")
    sign_in_as(support)
    get "/dashboard/api/payments/#{payment.id}"
    expect(json_body["can"]).to include("capture" => true, "cancel" => true, "refund" => false)
  end

  it "exports the filtered list as CSV without tokens" do
    create(:payment, merchant:, payment_method_token: "tok_secret")
    sign_in_as(viewer)
    get "/dashboard/api/payments/export.csv"
    expect(response.media_type).to eq("text/csv")
    expect(response.body.lines.first).to start_with("id,created_at,state")
    expect(response.body).not_to include("tok_secret")
  end

  it "does not let support export" do
    sign_in_as(support)
    get "/dashboard/api/payments/export.csv"
    expect(response).to have_http_status(:forbidden)
  end

  it "gives home the attention counts" do
    create(:payment, merchant:, state: "unknown")
    sign_in_as(viewer)
    get "/dashboard/api/home"
    expect(json_body["needs_attention"]).to eq("unknown" => 1)
  end

  describe "capture" do
    it "needs step-up, then calls CapturePayment" do
      payment = create(:payment, merchant:, state: "authorized")
      sign_in_as(support)
      post "/dashboard/api/payments/#{payment.id}/capture", params: {}.to_json, headers: ui_headers
      expect(json_body.dig("error", "code")).to eq("step_up_required")

      sign_in_as(support, stepped_up: true)
      post "/dashboard/api/payments/#{payment.id}/capture", params: {}.to_json, headers: ui_headers
      expect(response).to have_http_status(:accepted)
      expect(payment.captures.count).to eq(1)
    end
  end

  describe "refund" do
    let(:payment) { create(:payment, merchant:, state: "captured") }

    before { Ledger.record_capture!(payment, 2500) }

    it "requires a reason" do
      sign_in_as(support, stepped_up: true)
      post "/dashboard/api/payments/#{payment.id}/refunds", params: { amount_minor: 1000 }.to_json, headers: ui_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "reuses CreateRefund and replays a retried request with the same key" do
      sign_in_as(support, stepped_up: true)
      key = SecureRandom.uuid
      2.times do
        post "/dashboard/api/payments/#{payment.id}/refunds",
             params: { amount_minor: 1000, reason: "requested_by_customer" }.to_json, headers: ui_headers(idempotency_key: key)
      end
      expect(response).to have_http_status(:accepted)
      expect(payment.refunds.count).to eq(1)
      expect(response.headers["Idempotent-Replayed"]).to eq("true")
      expect(AuditEvent.where(action: "payment.refund_requested").count).to eq(1)
    end

    it "denies a viewer before the idempotency guard claims anything" do
      sign_in_as(viewer, stepped_up: true)
      expect do
        post "/dashboard/api/payments/#{payment.id}/refunds", params: { amount_minor: 1000, reason: "other" }.to_json,
                                                               headers: ui_headers
      end.not_to change(IdempotencyKey, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s a refund of the twin's payment from live mode" do
      twin_payment = create(:payment, merchant: merchant.test_twin!, state: "captured")
      sign_in_as(support, stepped_up: true)
      post "/dashboard/api/payments/#{twin_payment.id}/refunds", params: { reason: "other" }.to_json, headers: ui_headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
