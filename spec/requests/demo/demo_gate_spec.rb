# frozen_string_literal: true

require "rails_helper"

# The public demo needs no login, so production keeps it off unless asked.
RSpec.describe "Demo gate", type: :request do
  # Without the demo merchant the API is a 404 anyway; seed it so a 404 here
  # can only come from the gate.
  before { create(:merchant, name: DemoMerchant::NAME, livemode: true) }

  around do |example|
    previous = Rails.configuration.x.demo_enabled
    example.run
  ensure
    Rails.configuration.x.demo_enabled = previous
  end

  it "PR-1: the demo API and shell answer 404 when the demo is disabled" do
    Rails.configuration.x.demo_enabled = false

    get "/demo/api/ledger_summary"
    expect(response).to have_http_status(:not_found)
    post "/demo/api/reset"
    expect(response).to have_http_status(:not_found)
    get "/demo"
    expect(response).to have_http_status(:not_found)
  end

  it "PR-1: the demo works when enabled" do
    Rails.configuration.x.demo_enabled = true

    get "/demo/api/ledger_summary"
    expect(response).to have_http_status(:ok)
    get "/demo"
    expect(response).to have_http_status(:ok)
  end

  it "PR-1: production defaults to disabled, everything else to enabled" do
    expect(PayhubConfig.demo_enabled_default("production", nil)).to be(false)
    expect(PayhubConfig.demo_enabled_default("development", nil)).to be(true)
    expect(PayhubConfig.demo_enabled_default("test", nil)).to be(true)
  end

  it "PR-1: DEMO_ENABLED overrides the default, and only the exact value true enables" do
    expect(PayhubConfig.demo_enabled_default("production", "true")).to be(true)
    expect(PayhubConfig.demo_enabled_default("production", "false")).to be(false)
    expect(PayhubConfig.demo_enabled_default("development", "false")).to be(false)
    expect(PayhubConfig.demo_enabled_default("production", "1")).to be(false)
    expect(PayhubConfig.demo_enabled_default("production", "TRUE")).to be(false)
  end
end
