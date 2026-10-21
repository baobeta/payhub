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

  describe "TC-M16-1 the UI shells' directives" do
    def directives(path)
      get path
      response.headers["Content-Security-Policy"].split(";").to_h do |d|
        name, *values = d.strip.split
        [name, values]
      end
    end

    %w[/dashboard /ops /demo].each do |shell|
      it "TC-M16-1 #{shell} runs only same-origin scripts, no unsafe-inline or eval" do
        expect(directives(shell)["script-src"]).to eq(["'self'"])
      end

      it "TC-M16-1 #{shell} pins base-uri and form-action to self" do
        expect(directives(shell)).to include("base-uri" => ["'self'"], "form-action" => ["'self'"])
      end

      it "TC-M16-1 #{shell} keeps framing, fetches and images same-origin" do
        expect(directives(shell)).to include("default-src" => ["'self'"], "frame-ancestors" => ["'none'"],
                                             "connect-src" => ["'self'"], "img-src" => ["'self'", "data:"])
      end

      it "TC-M16-1 #{shell} blocks plugins with object-src 'none'" do
        pending("BUG: config/initializers/content_security_policy.rb sets no object-src; " \
                "it falls back to default-src 'self', while the OWASP CSP baseline asks for object-src 'none'")
        expect(directives(shell)["object-src"]).to eq(["'none'"])
      end
    end
  end
end
