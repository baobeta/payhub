# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operator do
  it "rejects an unknown role in the database, not only in the model" do
    op = create(:operator)
    expect { described_class.where(id: op.id).update_all(role: "superuser") }
      .to raise_error(ActiveRecord::StatementInvalid, /chk_operators_role/)
  end

  it "stores the TOTP secret encrypted" do
    op = create(:operator, otp_secret: "JBSWY3DPEHPK3PXP")
    raw = described_class.connection.select_value("SELECT otp_secret FROM operators WHERE id = '#{op.id}'")
    expect(raw).not_to include("JBSWY3DPEHPK3PXP")
    expect(op.reload.otp_secret).to eq("JBSWY3DPEHPK3PXP")
  end

  describe "#verify_otp!" do
    let(:op) { create(:operator) }
    let(:code) { ROTP::TOTP.new(op.otp_secret).now }

    it "accepts the current code once, then refuses it as a replay" do
      expect(op.verify_otp!(code)).to be(true)
      expect(op.verify_otp!(code)).to be(false)
    end
  end

  describe "lockout" do
    let(:op) { create(:operator) }

    it "locks for 30 minutes after 10 failures, like MerchantUser" do
      10.times { op.register_failure! }
      expect(op).to be_locked
      travel 31.minutes
      expect(op).not_to be_locked
    end

    it "starts counting afresh once a lock has expired, so one typo does not re-lock" do
      10.times { op.register_failure! }
      travel 31.minutes
      op.register_failure!
      expect(op).not_to be_locked
      expect(op.reload.failed_attempts).to eq(1)
    end

    it "resets the counter on success" do
      3.times { op.register_failure! }
      op.reset_failures!
      expect(op.reload.failed_attempts).to eq(0)
    end
  end

  describe ".invite!" do
    it "returns a raw token and stores only its digest, valid for 3 days" do
      op, token = described_class.invite!(email: "new@example.com", role: "ops", invited_by: nil)
      expect(op.invitation_digest).to eq(Digest::SHA256.hexdigest(token))
      expect(described_class.find_by_invitation_token(token)).to eq(op)
      travel 4.days
      expect(described_class.find_by_invitation_token(token)).to be_nil
    end

    it "invites every operator role" do
      %w[support ops approver admin].each do |role|
        op, token = described_class.invite!(email: "#{role}@example.com", role:, invited_by: nil)
        expect(op.role).to eq(role)
        expect(token).to be_present
      end
    end

    it "refuses an unknown role" do
      expect { described_class.invite!(email: "x@example.com", role: "superuser", invited_by: nil) }
        .to raise_error(ArgumentError, /unknown operator role/)
    end
  end
end
