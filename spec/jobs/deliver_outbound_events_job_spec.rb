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
end
