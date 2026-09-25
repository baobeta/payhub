# frozen_string_literal: true

require "rails_helper"

RSpec.describe CsvSafe do
  it "neutralises cells a spreadsheet would run as a formula" do
    expect(described_class.cell("=HYPERLINK(\"http://x\")")).to eq("'=HYPERLINK(\"http://x\")")
    %w[+1 -1 @SUM].each { |v| expect(described_class.cell(v)).to start_with("'") }
  end

  it "leaves ordinary values, numbers and nil alone" do
    expect(described_class.cell("sam@example.com")).to eq("sam@example.com")
    expect(described_class.cell(2500)).to eq(2500)
    expect(described_class.cell(nil)).to be_nil
  end
end
