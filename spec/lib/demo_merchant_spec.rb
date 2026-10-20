# frozen_string_literal: true

require "rails_helper"

RSpec.describe DemoMerchant do
  let!(:live) { create(:merchant, name: DemoMerchant::NAME, livemode: true) }

  describe ".twin" do
    it "is the live merchant's test twin, never the live merchant itself" do
      twin = described_class.twin
      expect(twin).to eq(live.test_twin!)
      expect(twin.livemode).to be(false)
      expect(twin).not_to eq(live)
    end
  end

  describe ".payments" do
    it "excludes rows created before the latest epoch" do
      old = create(:payment, merchant: live.test_twin!, created_at: 2.days.ago)
      DemoEpoch.create!(started_at: 1.day.ago)
      fresh = create(:payment, merchant: live.test_twin!)

      expect(described_class.payments).to contain_exactly(fresh)
      expect(described_class.payments).not_to include(old)
    end
  end
end
