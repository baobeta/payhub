# frozen_string_literal: true

require "rails_helper"

RSpec.describe DeliverOutboundEventsJob do
  it "never POSTs to a webhook URL that now resolves to a private address" do
    allow(WebhookUrlGuard).to receive(:allow_private?).and_return(false)
    allow(Resolv).to receive(:getaddresses).and_return(["10.0.0.7"]) # re-pointed after it was saved
    merchant = create(:merchant, webhook_url: "https://hooks.example.com/payhub")
    event = OutboundEvent.emit!(create(:payment, merchant:), "payment.captured")

    described_class.perform_now

    attempt = event.reload.delivery_attempts.last
    expect(attempt.error).to include('not delivered: webhook URL resolves to a private or reserved address')
    expect(a_request(:post, "https://hooks.example.com/payhub")).not_to have_been_made
  end

  describe "redelivering a dead event (Bug 7)" do
    let(:url) { "https://hooks.example.com/payhub" }
    let(:event) { OutboundEvent.emit!(create(:payment, merchant: create(:merchant, webhook_url: url)), "payment.captured") }

    before { allow(WebhookUrlGuard).to receive(:problem).and_return(nil) }

    def deliver_until_settled
      100.times do
        break unless event.reload.state == "pending"

        described_class.deliver_now(event.id)
      end
    end

    def kill(event)
      stub_request(:post, url).to_return(status: 500)
      deliver_until_settled
      expect(event.reload).to have_attributes(state: "dead", attempts: OutboundEvent::MAX_ATTEMPTS)
    end

    it "TC-H4-1: gives a full new budget; attempt numbers continue and dead-letters only after attempt 16" do
      kill(event)
      event.redeliver!

      described_class.deliver_now(event.id)
      expect(event.reload).to have_attributes(state: "pending", attempts: 9)
      expect(event.next_attempt_at).to be > Time.current

      deliver_until_settled
      expect(event.reload).to have_attributes(state: "dead", attempts: 16)
      expect(event.delivery_attempts.pluck(:attempt_number)).to eq((1..16).to_a)
    end

    it "TC-H4-2: a redelivered event the merchant accepts is delivered" do
      kill(event)
      event.redeliver!
      stub_request(:post, url).to_return(status: 200)

      described_class.deliver_now(event.id)

      expect(event.reload).to have_attributes(state: "delivered", attempts: 9)
      expect(event.delivered_at).to be_present
    end
  end
end
