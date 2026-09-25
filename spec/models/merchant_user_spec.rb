# frozen_string_literal: true

require "rails_helper"

RSpec.describe MerchantUser do
  let(:merchant) { create(:merchant) }

  it "allows exactly one active owner per merchant" do
    create(:merchant_user, merchant:, role: "owner")
    expect { create(:merchant_user, merchant:, role: "owner") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects an unknown role in the database, not only in the model" do
    user = create(:merchant_user, merchant:)
    expect { described_class.where(id: user.id).update_all(role: "superuser") }
      .to raise_error(ActiveRecord::StatementInvalid, /chk_merchant_users_role/)
  end

  it "belongs only to a live merchant" do
    expect(build(:merchant_user, merchant: merchant.test_twin!)).not_to be_valid
  end

  it "treats emails case-insensitively" do
    create(:merchant_user, email: "Sam@Example.com")
    expect { create(:merchant_user, email: "sam@example.com") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "stores the TOTP secret encrypted" do
    user = create(:merchant_user, otp_secret: "JBSWY3DPEHPK3PXP")
    raw = described_class.connection.select_value("SELECT otp_secret FROM merchant_users WHERE id = '#{user.id}'")
    expect(raw).not_to include("JBSWY3DPEHPK3PXP")
    expect(user.reload.otp_secret).to eq("JBSWY3DPEHPK3PXP")
  end

  describe "#verify_otp!" do
    let(:user) { create(:merchant_user) }
    let(:code) { ROTP::TOTP.new(user.otp_secret).now }

    it "accepts the current code once, then refuses it as a replay" do
      expect(user.verify_otp!(code)).to be(true)
      expect(user.verify_otp!(code)).to be(false)
    end

    it "refuses a malformed code without raising" do
      expect(user.verify_otp!("12ab56")).to be(false)
    end
  end

  describe "lockout" do
    let(:user) { create(:merchant_user) }

    it "locks for 30 minutes after 10 failures" do
      10.times { user.register_failure! }
      expect(user).to be_locked
      travel 31.minutes
      expect(user).not_to be_locked
    end

    it "resets the counter on success" do
      3.times { user.register_failure! }
      user.reset_failures!
      expect(user.reload.failed_attempts).to eq(0)
    end
  end

  describe ".invite!" do
    it "returns a raw token and stores only its digest, valid for 10 days" do
      user, token = described_class.invite!(merchant:, email: "new@example.com", role: "support", invited_by: nil)
      expect(user.invitation_digest).to eq(Digest::SHA256.hexdigest(token))
      expect(described_class.find_by_invitation_token(token)).to eq(user)
      travel 11.days
      expect(described_class.find_by_invitation_token(token)).to be_nil
    end

    it "never invites an owner" do
      expect { described_class.invite!(merchant:, email: "x@example.com", role: "owner", invited_by: nil) }
        .to raise_error(ArgumentError, /owner/)
    end
  end

  describe ".invite_first_owner!" do
    it "invites an owner when the merchant has none, and refuses a second" do
      user, token = described_class.invite_first_owner!(merchant:, email: "boss@example.com")
      expect(user.role).to eq("owner")
      expect(described_class.find_by_invitation_token(token)).to eq(user)
      expect { described_class.invite_first_owner!(merchant:, email: "boss2@example.com") }
        .to raise_error(ArgumentError, /already has an owner/)
    end
  end
end
