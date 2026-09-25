require "rails_helper"

RSpec.describe Merchant do
  describe ".create_with_api_key! / .authenticate" do
    it "returns the raw key once and stores only its digest" do
      merchant, raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")

      expect(raw).to start_with("sk_live_")
      expect(merchant.api_key_digest).to eq(Digest::SHA256.hexdigest(raw))
      expect(merchant.attributes.values).not_to include(raw)
    end

    it "authenticates with the raw key and rejects near-misses" do
      merchant, raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")

      expect(described_class.authenticate(raw)).to eq(merchant)
      expect(described_class.authenticate(raw + "x")).to be_nil
      expect(described_class.authenticate(raw[0..-2])).to be_nil
      expect(described_class.authenticate("")).to be_nil
      expect(described_class.authenticate(nil)).to be_nil
    end

    it "uses a constant-time comparison for the final check" do
      _merchant, raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")
      allow(ActiveSupport::SecurityUtils).to receive(:secure_compare).and_call_original

      described_class.authenticate(raw)

      expect(ActiveSupport::SecurityUtils).to have_received(:secure_compare).once
    end

    it "stores the key in api_keys" do
      merchant, raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")
      expect(merchant.api_keys.sole.digest).to eq(Digest::SHA256.hexdigest(raw))
    end

    it "stops authenticating once the key is revoked" do
      merchant, raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")
      merchant.api_keys.sole.update!(revoked_at: Time.current)
      expect(described_class.authenticate(raw)).to be_nil
    end

    it "authenticates a second key issued later" do
      merchant, _raw = described_class.create_with_api_key!(name: "Acme", default_currency: "EUR")
      _key, second = ApiKey.issue!(merchant:, livemode: true, name: "Second")
      expect(described_class.authenticate(second)).to eq(merchant)
    end
  end

  describe "#test_twin!" do
    it "creates one test-mode twin linked to the live merchant" do
      merchant = create(:merchant)
      twin = merchant.test_twin!
      expect(twin).to have_attributes(livemode: false, live_merchant_id: merchant.id,
                                      default_currency: merchant.default_currency)
      expect(merchant.test_twin!).to eq(twin)
    end

    it "never inherits the live webhook endpoint, so test events cannot reach production" do
      merchant = create(:merchant, webhook_url: "https://merchant.example/hooks")
      expect(merchant.test_twin!.webhook_url).to be_nil
    end

    it "returns the winner's twin after losing a creation race inside a transaction" do
      merchant = create(:merchant)
      winner = merchant.test_twin!
      loser = described_class.find(merchant.id)
      allow(loser).to receive(:test_twin).and_return(nil, winner) # stale read, then the reload

      described_class.transaction do
        expect(loser.test_twin!).to eq(winner)
        expect(described_class.count).to be_positive # the transaction is still usable
      end
    end
  end
end
