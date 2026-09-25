# frozen_string_literal: true

require "rails_helper"

RSpec.describe PspCallLog do
  let(:started) { Time.current }

  it "records a response with redacted bodies and the reference from the path" do
    described_class.record(psp: "nordpay", method: :get, path: "/charges/ph_#{'a' * 24}", request_body: nil,
                           status: 200, response_body: { "status" => "authorized" }, outcome: "ok", started_at: started)
    call = PspCall.sole
    expect(call).to have_attributes(psp_reference: "ph_#{'a' * 24}", operation: "GET /charges/:ref", http_status: 200)
  end

  it "records a timeout with no response" do
    described_class.record(psp: "nordpay", method: :post, path: "/charges",
                           request_body: { reference: "ph_#{'b' * 24}", payment_method_token: "tok_visa" },
                           status: nil, response_body: nil, outcome: "timeout", started_at: started)
    call = PspCall.sole
    expect(call).to have_attributes(outcome: "timeout", http_status: nil, response_redacted: nil,
                                    psp_reference: "ph_#{'b' * 24}")
    expect(call.request_redacted.to_json).not_to include("tok_visa")
  end

  it "finds the reference in query params and hides PSP ids in the operation" do
    described_class.record(psp: "kiripay", method: :get, path: "/charges/kp_#{'c' * 16}/refunds",
                           params: { "merchant_reference" => "ph_#{'d' * 24}" }, request_body: nil,
                           status: 200, response_body: nil, outcome: "ok", started_at: started)
    expect(PspCall.sole).to have_attributes(psp_reference: "ph_#{'d' * 24}", operation: "GET /charges/:id/refunds")
  end

  it "never lets a logging failure break the PSP call" do
    allow(PspCall).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect do
      described_class.record(psp: "nordpay", method: :get, path: "/x", request_body: nil, status: 200,
                             response_body: nil, outcome: "ok", started_at: started)
    end.not_to raise_error
  end

  it "leaves the caller's transaction usable when the insert fails in the database" do
    merchant = create(:merchant)
    ApplicationRecord.transaction do
      # psp_name is NOT NULL only in the database: a real PG error, not a validation.
      described_class.record(psp: nil, method: :get, path: "/x", request_body: nil, status: 200,
                             response_body: nil, outcome: "ok", started_at: started)
      expect(merchant.reload.name).to be_present
    end
    expect(PspCall.count).to eq(0)
  end
end
