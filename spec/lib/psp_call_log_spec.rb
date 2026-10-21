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

  it "caps an enormous response body at 16 KB plus a marker" do
    described_class.record(psp: "nordpay", method: :get, path: "/x", request_body: nil, status: 502,
                           response_body: "<html>#{'x' * 100_000}</html>", outcome: "http_error", started_at: started)
    stored = PspCall.sole.response_redacted
    expect(stored).to end_with("…[truncated]")
    expect(stored.bytesize).to be <= 16_500
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

  describe "the psp_call log line (K1; PCI DSS 10.2.1, 10.3: complete logs, shipped off the box)" do
    let(:pan) { "4242424242424242" }
    let(:lines) { [] }

    before { allow(Rails.logger).to receive(:info).and_wrap_original { |m, msg| lines << msg.to_s if msg.to_s.include?('"psp_call"'); m.call(msg) } }

    def record_card_call(**overrides)
      described_class.record(psp: "nordpay", method: :post, path: "/charges?token=tok_secret_1",
                             request_body: { reference: "ph_#{'e' * 24}", card_number: pan, client_secret: "cs_123" },
                             headers: { "Authorization" => "Bearer sk_nordpay_live" },
                             status: nil, response_body: { "pan" => pan }, outcome: "timeout", started_at: started,
                             error: "Net::ReadTimeout card #{pan}", **overrides)
    end

    it "TC-K1-3: a call recorded inside a transaction that rolls back loses its row, but its redacted log line was written" do
      ApplicationRecord.transaction do
        record_card_call
        raise ActiveRecord::Rollback
      end

      expect(PspCall.count).to eq(0)
      expect(lines.size).to eq(1)
      line = JSON.parse(lines.first)
      expect(line).to include("event" => "psp_call", "psp" => "nordpay", "method" => "POST", "status" => nil,
                              "outcome" => "timeout", "psp_reference" => "ph_#{'e' * 24}",
                              "path" => a_string_starting_with("POST /charges"), "duration_ms" => a_kind_of(Integer),
                              "error" => a_string_including("Net::ReadTimeout"))
      %W[#{pan} tok_secret_1 cs_123 sk_nordpay_live].each { |secret| expect(lines.first).not_to include(secret) }
    end

    it "counts a call made inside an open business transaction (DECISIONS #13: no PSP call under a lock)" do
      allow(Metrics).to receive(:increment).and_call_original

      ApplicationRecord.transaction { record_card_call }

      expect(Metrics).to have_received(:increment).with(:psp_call_in_transaction, psp: "nordpay").once
    end

    it "does not count a call made outside any business transaction" do
      allow(Metrics).to receive(:increment).and_call_original

      record_card_call

      expect(Metrics).not_to have_received(:increment).with(:psp_call_in_transaction, anything)
      expect(lines.size).to eq(1)
    end
  end
end
