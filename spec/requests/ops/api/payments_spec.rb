# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops payments", type: :request do
  let(:operator) { create(:operator, role: "ops") }

  before { sign_in_operator(operator) }

  describe "search" do
    it "finds a payment by id" do
      payment = create(:payment)
      get "/ops/api/payments", params: { q: payment.id }, headers: ui_headers
      expect(json_body["data"].sole["id"]).to eq(payment.id)
    end

    it "finds a payment by psp reference" do
      payment = create(:payment, psp_reference: "ph_abc")
      get "/ops/api/payments", params: { q: "ph_abc" }, headers: ui_headers
      expect(json_body["data"].sole["id"]).to eq(payment.id)
    end

    it "finds a merchant's payments by name prefix" do
      payment = create(:payment, merchant: create(:merchant, name: "Acme Rockets"))
      create(:payment, merchant: create(:merchant, name: "Other Ltd"))
      get "/ops/api/payments", params: { q: "Acme" }, headers: ui_headers
      expect(json_body["data"].map { |p| p["id"] }).to eq([payment.id])
    end
  end

  describe "detail" do
    it "includes redacted PSP calls and inbound webhooks" do
      payment = create(:payment, psp_reference: "ph_detail")
      PspCall.create!(psp_name: "nordpay", operation: "POST /charges", psp_reference: "ph_detail",
                      http_status: nil, outcome: "timeout", duration_ms: 1200, sent_at: 1.minute.ago)
      InboundEvent.create!(psp_name: "nordpay", external_id: "evt1", event_type: "payment.authorized",
                           psp_reference: "ph_detail", signature_valid: true, received_at: Time.current,
                           payload: { "payment_method_token" => "tok_secret" })

      get "/ops/api/payments/#{payment.id}", headers: ui_headers
      expect(response).to have_http_status(:ok)
      expect(json_body["psp_calls"].sole).to include("outcome" => "timeout")
      expect(json_body["inbound_events"].sole.dig("payload", "payment_method_token")).to eq("[REDACTED]")
    end
  end

  describe "poll now" do
    it "polls, audits and returns the detail" do
      payment = create(:payment, state: "unknown")
      allow(StuckPaymentSweeperJob).to receive(:poll_now)

      expect do
        post "/ops/api/payments/#{payment.id}/poll", headers: ui_headers
      end.to change(AuditEvent.where(action: "payment.polled"), :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(StuckPaymentSweeperJob).to have_received(:poll_now).with(payment)
    end

    it "forbids an approver, who cannot poll" do
      sign_in_operator(create(:operator, role: "approver"))
      post "/ops/api/payments/#{create(:payment).id}/poll", headers: ui_headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
