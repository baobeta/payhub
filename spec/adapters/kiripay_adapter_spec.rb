require "rails_helper"

RSpec.describe KiripayAdapter do
  subject(:adapter) { described_class.new(base_url: "http://kiripay.test", api_key: "kp_test_key", webhook_secrets: ["whsec"]) }

  let(:payment) { create(:payment, :vnd, psp_reference: "ph_vnd1") }
  let(:charge) do
    { "id" => "kp_1", "merchant_reference" => "ph_vnd1", "status" => "pending_redirect", "amount" => "500000",
      "currency" => "VND", "created_at" => "2026-01-01T10:00:00.000Z", "redirect_url" => "http://kiripay.test/pay/kp_1" }
  end

  describe "#authorize (create charge)" do
    it "sends MAJOR units — VND with no decimal point — and our reference as merchant_reference; returns RequiresAction" do
      stub_request(:post, "http://kiripay.test/charges")
        .with(body: hash_including("amount" => "500000", "currency" => "VND", "merchant_reference" => "ph_vnd1"))
        .to_return(status: 200, body: charge.to_json, headers: { "Content-Type" => "application/json" })

      result = adapter.authorize(payment)

      expect(result.status).to eq(PspAdapter::Result::Status::RequiresAction)
      expect(result.redirect_url).to eq("http://kiripay.test/pay/kp_1")
      expect(result.psp_charge_id).to eq("kp_1")
    end

    it "formats a two-decimal currency as major units with decimals" do
      thb = create(:payment, currency: "THB", amount_minor: 2550, psp_name: "kiripay", psp_reference: "ph_thb")
      stub_request(:post, "http://kiripay.test/charges")
        .with(body: hash_including("amount" => "25.5", "currency" => "THB"))
        .to_return(status: 200, body: charge.merge("merchant_reference" => "ph_thb", "currency" => "THB").to_json,
                   headers: { "Content-Type" => "application/json" })

      expect(adapter.authorize(thb).status).to eq(PspAdapter::Result::Status::RequiresAction)
    end
  end

  describe "#fetch (dedupe by merchant_reference — Kiripay has no idempotency)" do
    def stub_lookup(charges)
      stub_request(:get, "http://kiripay.test/charges").with(query: { merchant_reference: "ph_vnd1" })
        .to_return(status: 200, body: { data: charges }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "returns NotFound when Kiripay has nothing for our reference" do
      stub_lookup([])
      expect(adapter.fetch("ph_vnd1")).to be_not_found
    end

    it "returns the charge when there is exactly one" do
      stub_lookup([charge.merge("status" => "captured", "captured_at" => "2026-01-01T10:01:00.000Z")])
      result = adapter.fetch("ph_vnd1")
      expect(result.status).to eq(PspAdapter::Result::Status::Captured)
      expect(result.psp_timestamp).to eq(Time.utc(2026, 1, 1, 10, 1))
    end

    it "takes the EARLIEST when Kiripay created duplicates, and logs the rest for reconciliation" do
      later = charge.merge("id" => "kp_2", "created_at" => "2026-01-01T10:00:05.000Z")
      stub_lookup([charge, later])
      allow(Rails.logger).to receive(:warn)

      expect(adapter.fetch("ph_vnd1").psp_charge_id).to eq("kp_1")
      expect(Rails.logger).to have_received(:warn).with(a_string_including("kiripay.duplicate_charges"))
    end
  end

  describe "capabilities" do
    it "declares capture-only, full-refund-only, SEA currencies" do
      expect(adapter.separate_authorize_and_capture?).to be false
      expect(adapter.supports_partial_refund?).to be false
      expect(adapter.currencies).to eq(%w[VND THB IDR])
      expect { adapter.capture(payment, 1) }.to raise_error(PspAdapter::Rejected)
      expect { adapter.cancel(payment) }.to raise_error(PspAdapter::Rejected)
    end
  end

  describe "#verify_webhook" do
    let(:event) { { "id" => "evt_1", "type" => "charge.captured", "created_at" => "2026-01-01T10:01:00.000Z", "data" => charge.merge("status" => "captured") } }
    let(:body) { event.to_json }

    def signature(secret, ts = Time.current.to_i)
      "t=#{ts},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{ts}.#{body}")}"
    end

    it "accepts a correctly signed, fresh webhook and normalises it" do
      parsed = adapter.verify_webhook(body, { "X-Kiripay-Signature" => signature("whsec") })

      expect(parsed.external_id).to eq("evt_1")
      expect(parsed.psp_reference).to eq("ph_vnd1")
      expect(parsed.status).to eq(PspAdapter::Result::Status::Captured)
      expect(parsed.psp_timestamp).to eq(Time.utc(2026, 1, 1, 10, 1))
    end

    it "rejects a wrong secret, a missing header, and a stale timestamp" do
      expect { adapter.verify_webhook(body, { "X-Kiripay-Signature" => signature("wrong") }) }
        .to raise_error(PspAdapter::InvalidSignature, /mismatch/)
      expect { adapter.verify_webhook(body, {}) }.to raise_error(PspAdapter::InvalidSignature, /missing/)
      expect { adapter.verify_webhook(body, { "X-Kiripay-Signature" => signature("whsec", 1.hour.ago.to_i) }) }
        .to raise_error(PspAdapter::InvalidSignature, /too old/)
    end

    it "accepts the previous secret while rotating (DECISIONS #15)" do
      rotating = described_class.new(base_url: "http://kiripay.test", api_key: "kp_test_key", webhook_secrets: %w[new_secret whsec])
      expect(rotating.verify_webhook(body, { "X-Kiripay-Signature" => signature("whsec") }).external_id).to eq("evt_1")
      expect(rotating.verify_webhook(body, { "X-Kiripay-Signature" => signature("new_secret") }).external_id).to eq("evt_1")
    end

    it "uses a constant-time comparison" do
      allow(ActiveSupport::SecurityUtils).to receive(:secure_compare).and_call_original
      adapter.verify_webhook(body, { "X-Kiripay-Signature" => signature("whsec") })
      expect(ActiveSupport::SecurityUtils).to have_received(:secure_compare).once
    end

    it "rejects a body that is not a webhook as malformed, not as unsigned" do
      bad = "{}"
      sig = "t=#{Time.current.to_i},v1=#{OpenSSL::HMAC.hexdigest('SHA256', 'whsec', "#{Time.current.to_i}.#{bad}")}"
      expect { adapter.verify_webhook(bad, { "X-Kiripay-Signature" => sig }) }.to raise_error(PspAdapter::MalformedWebhook)
    end
  end
end
