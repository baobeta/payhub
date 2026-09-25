# frozen_string_literal: true

require "rails_helper"

RSpec.describe PspCallRedactor do
  it "removes the payment method token" do
    expect(described_class.redact({ "payment_method_token" => "tok_visa", "amount" => 2500 }))
      .to eq({ "payment_method_token" => "[REDACTED]", "amount" => 2500 })
  end

  it "redacts anything that looks like a card number, wherever it is" do
    redacted = described_class.redact({ "source" => { "number" => "4242424242424242" } })
    expect(redacted.to_json).not_to include("4242424242424242")
  end

  it "redacts secrets and signatures by key name, case-insensitively" do
    redacted = described_class.redact({ "Authorization" => "Bearer x", "webhook_secret" => "s", "Signature" => "sig" })
    expect(redacted.values.uniq).to eq(["[REDACTED]"])
  end

  it "keeps references, amounts, states and decline codes" do
    body = { "reference" => "ph_abc", "amount" => 2500, "status" => "declined", "decline_code" => "insufficient_funds" }
    expect(described_class.redact(body)).to eq(body)
  end

  it "walks arrays" do
    expect(described_class.redact({ "charges" => [{ "payment_method_token" => "tok" }] }))
      .to eq({ "charges" => [{ "payment_method_token" => "[REDACTED]" }] })
  end

  it "passes nil through" do
    expect(described_class.redact(nil)).to be_nil
  end

  it "masks a card number embedded in free text but keeps the text" do
    redacted = described_class.redact({ "message" => "card 4242 4242 4242 4242 declined" })
    expect(redacted).to eq({ "message" => "card [REDACTED] declined" })
  end

  it "keeps long digit strings that are not card numbers (fail Luhn)" do
    body = { "order" => "1234567890123456", "amount" => 1_234_567_890_123 }
    expect(described_class.redact(body)).to eq(body)
  end

  it "catches api keys spelled either way" do
    redacted = described_class.redact({ "api_key" => "k", "apiKey" => "k", "x-api-key" => "k" })
    expect(redacted.values.uniq).to eq(["[REDACTED]"])
  end

  it "never raises; masks the whole body instead" do
    evil = Object.new
    def evil.to_s = raise("boom")
    expect(described_class.redact({ evil => 1 })).to eq("[REDACTED]")
  end
end
