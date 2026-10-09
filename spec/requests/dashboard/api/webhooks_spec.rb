# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard webhooks and events", type: :request do
  let(:merchant) { create(:merchant) }
  let(:developer) { create(:merchant_user, merchant:, role: "developer") }

  def set_url(url)
    patch "/dashboard/api/webhook_endpoint", params: { url: }.to_json, headers: ui_headers
  end

  it "sets the endpoint URL and rejects a non-http one" do
    sign_in_as(developer, stepped_up: true)
    set_url("ftp://example.com/hook")
    expect(response).to have_http_status(:unprocessable_content)
    set_url("https://example.com/hook")
    expect(json_body).to include("url" => "https://example.com/hook", "livemode" => true)
    expect(merchant.reload.webhook_url).to eq("https://example.com/hook")
  end

  it "refuses an endpoint on a private address in production" do
    allow(WebhookUrlGuard).to receive(:allow_private?).and_return(false)
    sign_in_as(developer, stepped_up: true)
    set_url("https://169.254.169.254/latest/meta-data")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body.dig("error", "details", "url").first).to include('private or reserved')
  end

  it "keeps the test-mode endpoint separate from live" do
    sign_in_as(developer, livemode: false, stepped_up: true)
    set_url("https://example.com/test-hook")
    expect(merchant.reload.webhook_url).to be_nil
    expect(merchant.test_twin!.webhook_url).to eq("https://example.com/test-hook")
  end

  it "reveals the secret only after step-up, and audits it" do
    sign_in_as(developer)
    post "/dashboard/api/webhook_endpoint/reveal_secret", headers: ui_headers
    expect(json_body.dig("error", "code")).to eq("step_up_required")

    sign_in_as(developer, stepped_up: true)
    post "/dashboard/api/webhook_endpoint/reveal_secret", headers: ui_headers
    expect(json_body["secret"]).to eq(merchant.webhook_secret)
    expect(AuditEvent.last.action).to eq("webhook.secret_revealed")
  end

  it "never shows the full secret on GET" do
    sign_in_as(developer)
    get "/dashboard/api/webhook_endpoint"
    expect(response.body).not_to include(merchant.webhook_secret)
    expect(json_body["secret_last4"]).to eq(merchant.webhook_secret.last(4))
  end

  it "rolls the secret and keeps the old one signing for 24h" do
    sign_in_as(developer, stepped_up: true)
    post "/dashboard/api/webhook_endpoint/roll_secret", headers: ui_headers
    expect(json_body["previous_secret_expires_at"]).to be_present
    expect(merchant.reload.webhook_signing_secrets.size).to eq(2)
  end

  it "is forbidden to support" do
    sign_in_as(create(:merchant_user, merchant:, role: "support"))
    get "/dashboard/api/webhook_endpoint"
    expect(response).to have_http_status(:forbidden)
  end

  describe "events" do
    let(:payment) { create(:payment, merchant:) }
    let!(:event) { OutboundEvent.emit!(payment, "payment.captured") }

    it "lists and shows the merchant's events with attempts" do
      sign_in_as(developer)
      get "/dashboard/api/events"
      expect(json_body["data"].pluck("id")).to include(event.id) # creating the payment emits one too
      get "/dashboard/api/events/#{event.id}"
      expect(json_body).to include("delivery_attempts")
    end

    it "redelivers only dead events" do
      sign_in_as(developer)
      post "/dashboard/api/events/#{event.id}/redeliver", headers: ui_headers
      expect(response).to have_http_status(:bad_request)

      event.update_columns(state: "dead") # rubocop:disable Rails/SkipsModelValidations
      post "/dashboard/api/events/#{event.id}/redeliver", headers: ui_headers
      expect(response).to have_http_status(:accepted)
      expect(event.reload.state).to eq("pending")
    end
  end
end
