require "rails_helper"

RSpec.describe Tracing do
  it "returns empty ids when no valid span is active" do
    expect(described_class.ids).to eq({})
  end

  it "wraps a block and returns its value" do
    result = described_class.in_span("payhub.test", attributes: { "payhub.outcome" => "ok" }) { :done }

    expect(result).to eq(:done)
  end
end
