require "rails_helper"

RSpec.describe Merchant do
  describe ".create_with_api_key! / .authenticate" do
    it "returns the raw key once and stores only its digest" do
      merchant, raw = Merchant.create_with_api_key!(name: "Acme", default_currency: "EUR")

      expect(raw).to start_with("sk_live_")
      expect(merchant.api_key_digest).to eq(Digest::SHA256.hexdigest(raw))
      expect(merchant.attributes.values).not_to include(raw)
    end

    it "authenticates with the raw key and rejects near-misses" do
      merchant, raw = Merchant.create_with_api_key!(name: "Acme", default_currency: "EUR")

      expect(Merchant.authenticate(raw)).to eq(merchant)
      expect(Merchant.authenticate(raw + "x")).to be_nil
      expect(Merchant.authenticate(raw[0..-2])).to be_nil
      expect(Merchant.authenticate("")).to be_nil
      expect(Merchant.authenticate(nil)).to be_nil
    end

    it "uses a constant-time comparison for the final check" do
      _merchant, raw = Merchant.create_with_api_key!(name: "Acme", default_currency: "EUR")
      expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).and_call_original
      Merchant.authenticate(raw)
    end
  end
end
