# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignIn do
  let!(:user) { create(:merchant_user, email: "sam@example.com") }
  let(:password) { "correct horse battery staple" }

  it "accepts the right password" do
    expect(described_class.password(MerchantUser, email: "SAM@example.com", password:))
      .to have_attributes(status: :ok, principal: user)
  end

  it "answers an unknown email exactly like a wrong password" do
    unknown = described_class.password(MerchantUser, email: "nobody@example.com", password: "x" * 12)
    wrong = described_class.password(MerchantUser, email: "sam@example.com", password: "x" * 12)
    expect([unknown.status, wrong.status]).to eq(%i[invalid invalid])
  end

  it "locks after 10 wrong passwords and then refuses even the right one" do
    10.times { described_class.password(MerchantUser, email: "sam@example.com", password: "x" * 12) }
    expect(described_class.password(MerchantUser, email: "sam@example.com", password:))
      .to have_attributes(status: :locked)
  end

  it "refuses a disabled user and an invitation that was never accepted" do
    user.update!(disabled_at: Time.current)
    invited, _token = MerchantUser.invite!(merchant: user.merchant, email: "new@example.com", role: "viewer", invited_by: nil)
    expect(described_class.password(MerchantUser, email: "sam@example.com", password:).status).to eq(:invalid)
    expect(described_class.password(MerchantUser, email: invited.email, password: "anything-long-enough").status).to eq(:invalid)
  end
end
