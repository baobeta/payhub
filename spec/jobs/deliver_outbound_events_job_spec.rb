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

  describe "the retry schedule (H8; Stripe retries for about 3 days)" do
    let(:url) { "https://hooks.example.com/payhub" }
    let(:event) { OutboundEvent.emit!(create(:payment, merchant: create(:merchant, webhook_url: url)), "payment.captured") }

    before do
      allow(WebhookUrlGuard).to receive(:problem).and_return(nil)
      stub_request(:post, url).to_return(status: 500)
    end

    # Delivers at each due time until the event leaves `pending`; returns the waits.
    def fail_until_dead
      waits = []
      while event.reload.state == "pending"
        travel_to(event.next_attempt_at)
        before = Time.current
        described_class.deliver_now(event.id)
        waits << (event.next_attempt_at - before).round if event.reload.state == "pending"
      end
      waits
    end

    it "TC-H8-2: backs off 1m, 5m, 30m, 2h, 8h, 24h, 36h, and is dead after attempt 8, ~70.6h after the first" do
      freeze_time
      first = event.next_attempt_at

      waits = fail_until_dead

      expect(waits).to eq([1.minute, 5.minutes, 30.minutes, 2.hours, 8.hours, 24.hours, 36.hours].map(&:to_i))
      expect(event).to have_attributes(state: "dead", attempts: 8)
      expect(event.delivery_attempts.maximum(:created_at) - first).to eq(4236.minutes.to_i) # 70.6h
    end

    it "TC-H8-2: a redelivery restarts the schedule from 1m for its 8 new attempts" do
      freeze_time
      fail_until_dead
      event.redeliver!

      waits = fail_until_dead

      expect(waits).to eq([1.minute, 5.minutes, 30.minutes, 2.hours, 8.hours, 24.hours, 36.hours].map(&:to_i))
      expect(event).to have_attributes(state: "dead", attempts: 16)
    end
  end
end
