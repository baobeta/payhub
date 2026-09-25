# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecoveryCode do
  let(:user) { create(:merchant_user) }

  it "issues 10 codes, stores digests, and replaces the old set" do
    first = described_class.regenerate!(user)
    second = described_class.regenerate!(user)
    expect(second.size).to eq(10)
    expect(described_class.where(principal: user).count).to eq(10)
    expect(described_class.consume!(user, first.first)).to be(false)
  end

  it "accepts each code once, ignoring case and dashes" do
    codes = described_class.regenerate!(user)
    expect(described_class.consume!(user, codes.first.upcase)).to be(true)
    expect(described_class.consume!(user, codes.first)).to be(false)
  end
end
