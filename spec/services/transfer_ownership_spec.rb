# frozen_string_literal: true

require "rails_helper"

RSpec.describe TransferOwnership do
  let(:merchant) { create(:merchant) }
  let(:owner) { create(:merchant_user, merchant:, role: "owner") }
  let(:admin) { create(:merchant_user, merchant:, role: "admin") }

  it "swaps roles so exactly one owner remains" do
    described_class.call(owner:, to: admin)
    expect([owner.reload.role, admin.reload.role]).to eq(%w[admin owner])
    expect(merchant.merchant_users.where(role: "owner").count).to eq(1)
  end

  it "refuses a member who has not enrolled 2FA, or someone from another merchant" do
    invited, = MerchantUser.invite!(merchant:, email: "new@example.com", role: "viewer", invited_by: owner)
    expect { described_class.call(owner:, to: invited) }.to raise_error(described_class::Refused)
    expect { described_class.call(owner:, to: create(:merchant_user)) }.to raise_error(described_class::Refused)
  end
end
