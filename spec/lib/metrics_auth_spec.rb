require "rails_helper"

RSpec.describe MetricsAuth do
  def authorized?(header, token: "s3cret")
    described_class.authorized?(header, token: token)
  end

  it "PR-3: no header is refused" do
    expect(authorized?(nil)).to be(false)
  end

  it "PR-3: the scheme with no credentials is refused" do
    expect(authorized?("Bearer")).to be(false)
  end

  it "PR-3: an empty bearer is refused against a set token" do
    expect(authorized?("Bearer ")).to be(false)
  end

  it "PR-3: a token without the Bearer scheme is refused" do
    expect(authorized?("s3cret")).to be(false)
  end

  it "PR-3: a wrong token is refused" do
    expect(authorized?("Bearer wrong")).to be(false)
  end

  it "PR-3: the right token is accepted" do
    expect(authorized?("Bearer s3cret")).to be(true)
  end

  it "PR-3: the scheme is case-insensitive" do
    expect(authorized?("bearer s3cret")).to be(true)
  end

  it "PR-3: surrounding whitespace on the credentials is ignored" do
    expect(authorized?("Bearer s3cret \n")).to be(true)
  end

  it "PR-3: surrounding whitespace on the configured token is ignored" do
    expect(authorized?("Bearer s3cret", token: "s3cret\n")).to be(true)
  end

  it "PR-3: outside production a blank token leaves scraping open" do
    expect(authorized?(nil, token: "")).to be(true)
  end

  context "when in production" do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it "PR-3: a blank token refuses every scrape" do
      expect(authorized?("Bearer ", token: "")).to be(false)
    end

    it "PR-3: a blank token logs one warning at boot, without failing it" do
      allow(Rails.logger).to receive(:warn)
      described_class.warn_if_unset_in_production(token: "")
      expect(Rails.logger).to have_received(:warn).once.with(%r{METRICS_TOKEN.*/metrics})
    end

    it "PR-3: a set token logs nothing at boot" do
      allow(Rails.logger).to receive(:warn)
      described_class.warn_if_unset_in_production(token: "s3cret")
      expect(Rails.logger).not_to have_received(:warn)
    end
  end

  it "PR-3: outside production an unset token logs nothing at boot" do
    allow(Rails.logger).to receive(:warn)
    described_class.warn_if_unset_in_production(token: "")
    expect(Rails.logger).not_to have_received(:warn)
  end
end
