require "rails_helper"

RSpec.describe PayhubConfig do
  describe ".redis_url" do
    it "uses REDIS_URL when it is set, in any environment" do
      expect(described_class.redis_url("development", "redis://redis:6379/0")).to eq("redis://redis:6379/0")
      expect(described_class.redis_url("production", "redis://cache:6379/1")).to eq("redis://cache:6379/1")
    end

    it "defaults development and test to compose's host port 6380" do
      expect(described_class.redis_url("development", nil)).to eq("redis://localhost:6380/0")
      expect(described_class.redis_url("test", nil)).to eq("redis://localhost:6380/0")
    end

    it "keeps production's default on 6379" do
      expect(described_class.redis_url("production", nil)).to eq("redis://localhost:6379/0")
    end
  end
end
