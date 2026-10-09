# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Content security policy", type: :request do
  it "protects the UI pages" do
    get "/dashboard"
    csp = response.headers["Content-Security-Policy"]
    expect(csp).to include("frame-ancestors 'none'", "default-src 'self'")
  end

  # Browsers apply CSP only to documents they render, so the same header on a
  # JSON response is harmless (and what OWASP recommends for APIs).
  it "sends the same restrictive policy on JSON responses" do
    get "/healthz"
    expect(response.headers["Content-Security-Policy"]).to include("frame-ancestors 'none'")
  end
end
