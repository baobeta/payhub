# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebhookUrlGuard do
  def check(url, resolves_to: nil)
    allow(Resolv).to receive(:getaddresses).and_return(Array(resolves_to)) if resolves_to
    described_class.problem(url, allow_private: false)
  end

  it "accepts a public https endpoint" do
    expect(check("https://hooks.example.com/payhub", resolves_to: "93.184.216.34")).to be_nil
  end

  it "refuses loopback, private, link-local and metadata addresses" do
    {
      "https://localhost/x" => "127.0.0.1",
      "https://internal.example/x" => "10.1.2.3",
      "https://db.example/x" => "192.168.0.5",
      "https://metadata.example/x" => "169.254.169.254",
      "https://v6.example/x" => "fd00::1",
      "https://loop6.example/x" => "::1"
    }.each do |url, ip|
      expect(check(url, resolves_to: ip)).to include('private or reserved address'), url
    end
  end

  it "refuses a literal private IP without a DNS lookup" do
    expect(described_class.problem("https://10.0.0.1/hook", allow_private: false)).to include('private')
  end

  it "refuses a host that does not resolve" do
    expect(check("https://nowhere.invalid/x", resolves_to: [])).to include('does not resolve')
  end

  it "refuses when ANY resolved address is private (DNS rebinding with mixed answers)" do
    expect(check("https://mixed.example/x", resolves_to: ["93.184.216.34", "10.0.0.1"])).to include('private')
  end

  it "allows private addresses when told to (development)" do
    expect(described_class.problem("http://localhost:4000/hook", allow_private: true)).to be_nil
  end

  describe "TC-H6-1: production rejects http://, IPv4-mapped, and 0.0.0.0 URLs" do
    # Stub Rails.env as production so allow_private? returns false
    before { allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production")) }

    it "TC-H6-1 refuses a plain http:// URL" do
      expect(described_class.problem("http://hooks.example.com/payhub")).to include("must use https")
    end

    it "TC-H6-1 refuses an IPv4-mapped private address (https://[::ffff:10.0.0.1])" do
      # ::ffff:10.0.0.1 is the IPv4-mapped form of 10.0.0.1 — private range
      expect(described_class.problem("https://[::ffff:10.0.0.1]/hook")).to include("private or reserved")
    end

    it "TC-H6-1 refuses https://0.0.0.0" do
      expect(described_class.problem("https://0.0.0.0/hook")).to include("private or reserved")
    end
  end
end
