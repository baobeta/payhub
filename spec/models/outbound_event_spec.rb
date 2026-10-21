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

  describe "sequence (H8; Adyen's sequenceNumber)" do
    it "TC-H8-1: numbers one payment's events 1, 2, 3 in creation order; another payment starts at 1" do
      payment = create(:payment) # emits payment.created
      described_class.emit!(payment, "payment.authorized")
      described_class.emit!(payment, "payment.captured")
      other = create(:payment, merchant: payment.merchant)

      events = described_class.where(payment:).order(:created_at, :id).to_a
      expect(events.map(&:event_type)).to eq(%w[payment.created payment.authorized payment.captured])
      expect(events.map { _1.envelope["sequence"] }).to eq([1, 2, 3])
      expect(described_class.find_by!(payment: other).envelope["sequence"]).to eq(1)
    end
  end
end
