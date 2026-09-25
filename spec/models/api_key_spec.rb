# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiKey do
  let(:merchant) { create(:merchant) }

  describe ".issue!" do
    it "returns the raw key once and stores only its digest, prefix and last 4" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      expect(raw).to start_with("sk_live_")
      expect(key.digest).to eq(Digest::SHA256.hexdigest(raw))
      expect(key.prefix).to eq("sk_live_")
      expect(key.last4).to eq(raw[-4..])
      expect(key.attributes.values).not_to include(raw)
    end

    it "issues test keys with the sk_test_ prefix" do
      _key, raw = described_class.issue!(merchant:, livemode: false, name: "CI")
      expect(raw).to start_with("sk_test_")
    end
  end

  describe ".authenticate" do
    it "finds an active key" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      expect(described_class.authenticate(raw)).to eq(key)
    end

    it "rejects a revoked key" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      key.update!(revoked_at: Time.current)
      expect(described_class.authenticate(raw)).to be_nil
    end

    it "accepts a rolled key until it expires, then rejects it" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      key.update!(expires_at: 1.hour.from_now)
      expect(described_class.authenticate(raw)).to eq(key)
      travel 2.hours
      expect(described_class.authenticate(raw)).to be_nil
    end

    it "records last use at most once a minute" do
      key, raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      freeze_time do
        described_class.authenticate(raw)
        expect(key.reload.last_used_at).to eq(Time.current)
        travel 30.seconds
        described_class.authenticate(raw)
        expect(key.reload.last_used_at).to eq(30.seconds.ago)
      end
    end

    it "returns nil for blank input" do
      expect(described_class.authenticate("")).to be_nil
    end
  end
end
