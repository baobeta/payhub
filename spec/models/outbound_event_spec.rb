# frozen_string_literal: true

require "rails_helper"

RSpec.describe OutboundEvent do
  describe "#envelope" do
    it "says whether the event is live, so a receiver can drop test-mode events" do
      live = create(:merchant)
      live_event = described_class.emit!(create(:payment, merchant: live), "payment.captured")
      test_event = described_class.emit!(create(:payment, merchant: live.test_twin!), "payment.captured")

      expect(live_event.envelope).to include("livemode" => true)
      expect(test_event.envelope).to include("livemode" => false)
    end
  end
end
