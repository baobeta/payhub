# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityMailer do
  let(:user) { create(:merchant_user) }

  def last_mail = ActionMailer::Base.deliveries.last

  it "tells the user where a new sign-in came from" do
    described_class.new_sign_in(user, ip: "1.2.3.4", user_agent: "Firefox").deliver_now
    expect(last_mail.to).to eq([user.email])
    expect(last_mail.body.to_s).to include("1.2.3.4", "Firefox")
  end

  # M12 (NIST 800-63B §4.1.2.1 / §4.2): the person hears about every change to
  # how they sign in.
  {
    password_changed: "password",
    recovery_codes_regenerated: "recovery codes",
    recovery_code_used: "recovery code"
  }.each do |method, phrase|
    it "TC-M12-1 #{method} goes to the user and says what happened" do
      described_class.public_send(method, user).deliver_now
      expect(last_mail.to).to eq([user.email])
      expect(last_mail.body.to_s).to include(phrase)
    end
  end

  it "TC-M12-5 otp_reset carries the single-use reset link and says it expires in 72 hours" do
    described_class.otp_reset(user, "tok-123").deliver_now
    expect(last_mail.to).to eq([user.email])
    expect(last_mail.body.to_s).to include("authenticator", "/dashboard/reset-authenticator?token=tok-123", "72 hours")
  end

  it "TC-M12-1 account_locked says until when" do
    described_class.account_locked(user, until_at: Time.utc(2026, 10, 21, 12, 30)).deliver_now
    expect(last_mail.to).to eq([user.email])
    expect(last_mail.body.to_s).to include("locked", "2026-10-21T12:30:00Z")
  end

  it "TC-M7-4 sessions_revoked says how many sessions ended" do
    described_class.sessions_revoked(user, count: 2).deliver_now
    expect(last_mail.body.to_s).to include("2 other sessions")
  end

  it "TC-M12-2 account_changed tells the owner what changed and who did it" do
    described_class.account_changed(user, event: "api_key.revoked", actor: "dev@example.com", detail: "Checkout",
                                    at: Time.current).deliver_now
    expect(last_mail.to).to eq([user.email])
    expect(last_mail.subject).to include("API key revoked")
    expect(last_mail.body.to_s).to include("dev@example.com", "revoked an API key", "Checkout")
  end

  it "TC-M12-6 account_changed states when the change happened, not when the email went out" do
    at = Time.utc(2026, 10, 20, 9, 15)
    travel_to(Time.utc(2026, 10, 21, 18, 0)) do
      described_class.account_changed(user, event: "api_key.revoked", actor: "dev@example.com", at:).deliver_now
    end
    expect(last_mail.body.to_s).to include("2026-10-20T09:15:00Z")
    expect(last_mail.body.to_s).not_to include("2026-10-21T18:00:00Z")
  end
end
