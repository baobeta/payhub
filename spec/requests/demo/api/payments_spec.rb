# frozen_string_literal: true

require "rails_helper"

# The public demo: no session, one merchant, its test twin.
RSpec.describe "Demo payments", type: :request do
  let!(:demo) { create(:merchant, name: DemoMerchant::NAME, livemode: true) }

  before do
    DemoEpoch.create!(started_at: 1.hour.ago)
    create(:fx_rate) # VND->EUR, for the wallet_redirect scenario
  end

  describe "POST /demo/api/payments" do
    %w[success decline timeout_then_webhook timeout_needs_operator wallet_redirect].each do |scenario|
      it "creates a #{scenario} payment on the demo twin" do
        post "/demo/api/payments", params: { scenario: }

        expect(response).to have_http_status(:accepted)
        payment = Payment.find(json_body["id"])
        expect(payment.merchant).to eq(demo.test_twin!)
        expect(payment.metadata).to eq("demo_scenario" => scenario)
        # The live merchant is never touched by the demo.
        expect(demo.payments.reload).to be_empty
      end
    end

    it "422s an unknown scenario" do
      post "/demo/api/payments", params: { scenario: "anything" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body.dig("error", "code")).to eq("validation_failed")
    end
  end

  describe "GET /demo/api/payments/:id" do
    it "returns the payment with its timeline" do
      payment = create(:payment, merchant: demo.test_twin!)
      get "/demo/api/payments/#{payment.id}"

      expect(response).to have_http_status(:ok)
      expect(json_body["id"]).to eq(payment.id)
      expect(json_body).to have_key("timeline")
    end

    it "404s another merchant's payment rather than 403, so ids are not confirmed" do
      get "/demo/api/payments/#{create(:payment).id}"
      expect(response).to have_http_status(:not_found)
    end

    it "404s a payment from before the current epoch" do
      payment = create(:payment, merchant: demo.test_twin!, created_at: 1.day.ago)
      get "/demo/api/payments/#{payment.id}"
      expect(response).to have_http_status(:not_found)
    end
  end
end
