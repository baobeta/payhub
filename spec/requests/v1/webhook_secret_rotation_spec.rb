require "rails_helper"

# DECISIONS #15: a merchant rotating its webhook secret must not lose a single
# delivery — for the grace period every webhook verifies with old OR new.
RSpec.describe "Outbound webhook secret rotation", type: :request do
  let!(:merchant) { create_merchant_with_key(webhook_url: "https://merchant.test/hooks").first }

  def delivered_signature
    stub_request(:post, "https://merchant.test/hooks").to_return(status: 200)
    DeliverOutboundEventsJob.perform_now
    req = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last
    [req.headers["X-Payhub-Signature"], req.body]
  end

  it "signs with both secrets during the grace period, and only the new one after" do
    old = merchant.webhook_secret
    fresh = merchant.rotate_webhook_secret!
    create(:payment, merchant: merchant)

    header, body = delivered_signature
    [fresh, old].each do |secret|
      expect { WebhookSignature.verify_timestamped!(body, header, secrets: [secret], tolerance: 5.minutes) }.not_to raise_error
    end

    travel 25.hours do
      create(:payment, merchant: merchant)
      header, body = delivered_signature
      expect(header.scan("v1=").size).to eq(1)
      expect { WebhookSignature.verify_timestamped!(body, header, secrets: [old], tolerance: 5.minutes) }
        .to raise_error(WebhookSignature::Invalid)
    end
  end
end
