require "rails_helper"

RSpec.describe Currency do
  describe ".to_display" do
    it "formats two-decimal currencies" do
      expect(described_class.to_display(2500, "EUR")).to eq("25.00")
      expect(described_class.to_display(5, "GBP")).to eq("0.05")
      expect(described_class.to_display(-1999, "USD")).to eq("-19.99")
    end

    it "does NOT divide zero-decimal VND by 100" do
      expect(described_class.to_display(50_000, "VND")).to eq("50000")
    end

    it "raises on an unknown currency rather than guessing an exponent" do
      expect { described_class.to_display(100, "XXX") }.to raise_error(Currency::Unsupported)
    end
  end

  describe ".to_major / .from_major" do
    it "round-trips exactly, without floats" do
      expect(described_class.to_major(2500, "EUR")).to eq(BigDecimal("25"))
      expect(described_class.to_major(2500, "EUR")).to be_a(BigDecimal)
      expect(described_class.from_major("25.00", "EUR")).to eq(2500)
      expect(described_class.from_major(50_000, "VND")).to eq(50_000)
    end
  end

  it "covers every currency the two PSPs speak" do
    expect(described_class::SUPPORTED).to match_array(%w[EUR GBP USD VND THB IDR])
  end
end
