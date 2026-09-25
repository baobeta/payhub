# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeMemberRole do
  let(:merchant) { create(:merchant) }
  let(:owner) { create(:merchant_user, merchant:, role: "owner") }
  let(:admin) { create(:merchant_user, merchant:, role: "admin") }
  let(:member) { create(:merchant_user, merchant:, role: "viewer") }

  it "changes another member's role" do
    expect(described_class.call(actor: admin, member:, role: "support").role).to eq("support")
  end

  it "refuses your own role, the owner's role, and granting owner" do
    expect { described_class.call(actor: admin, member: admin, role: "viewer") }.to raise_error(described_class::Refused, /own/)
    expect { described_class.call(actor: admin, member: owner, role: "viewer") }.to raise_error(described_class::Refused, /owner/)
    expect { described_class.call(actor: admin, member:, role: "owner") }.to raise_error(described_class::Refused, /Role/)
  end

  it "removes a member and ends their sessions" do
    session = Session.create!(principal: member, ip: "1.1.1.1", user_agent: "x")
    described_class.remove(actor: admin, member:)
    expect(member.reload.disabled_at).to be_present
    expect(session.reload.revoked_at).to be_present
  end

  it "refuses to remove yourself or the owner" do
    expect { described_class.remove(actor: admin, member: admin) }.to raise_error(described_class::Refused)
    expect { described_class.remove(actor: admin, member: owner) }.to raise_error(described_class::Refused)
  end
end
