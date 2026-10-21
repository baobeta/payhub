# frozen_string_literal: true

require "rails_helper"

# M12: mandatory security emails (NIST 800-63B §4.1.2.1 / §4.2; Stripe).
RSpec.describe "Security emails", type: :request do
  let(:merchant) { create(:merchant) }
  let!(:owner) { create(:merchant_user, merchant:, role: "owner", email: "owner@example.com") }
  let(:admin) { create(:merchant_user, merchant:, role: "admin", email: "admin@example.com") }

  def code_for(user) = ROTP::TOTP.new(user.reload.otp_secret).now

  describe "to the user" do
    it "TC-M12-1 password changed: one email" do
      sign_in_as(admin, stepped_up: true)
      expect do
        patch "/dashboard/api/me/password",
              params: { current_password: "correct horse battery staple", new_password: "a brand new password" }.to_json,
              headers: ui_headers
      end.to have_enqueued_mail(SecurityMailer, :password_changed).once
    end

    it "TC-M12-1 recovery codes regenerated: one email" do
      sign_in_as(admin, stepped_up: true)
      expect do
        post "/dashboard/api/me/recovery_codes", headers: ui_headers
      end.to have_enqueued_mail(SecurityMailer, :recovery_codes_regenerated).once
    end

    it "TC-M12-1 a recovery code used to sign in: one email" do
      codes = RecoveryCode.regenerate!(admin)
      post "/dashboard/api/session", params: { email: admin.email, password: "correct horse battery staple" }.to_json,
                                     headers: ui_headers
      expect do
        post "/dashboard/api/session/recovery", params: { code: codes.first }.to_json, headers: ui_headers
      end.to have_enqueued_mail(SecurityMailer, :recovery_code_used).once
    end

    it "TC-M12-1 account locked: exactly one email, on the failure that locks" do
      expect do
        11.times do
          post "/dashboard/api/session", params: { email: admin.email, password: "wrong-password-123" }.to_json,
                                         headers: ui_headers
        end
      end.to have_enqueued_mail(SecurityMailer, :account_locked).once
    end
  end

  describe "to the owner" do
    def owner_mails(&)
      ActionMailer::Base.deliveries.clear
      perform_enqueued_jobs(&)
      ActionMailer::Base.deliveries.select { |m| m.to == [owner.email] && m.subject.start_with?("PayHub:") }
    end

    before { sign_in_as(admin, stepped_up: true) }

    it "TC-M12-2 API key created, rolled and revoked each email the owner, naming the actor" do
      mails = owner_mails do
        post "/dashboard/api/api_keys", params: { name: "Checkout" }.to_json, headers: ui_headers
        key_id = json_body["id"]
        post "/dashboard/api/api_keys/#{key_id}/roll", params: { expires_in: "now" }.to_json, headers: ui_headers
        post "/dashboard/api/api_keys/#{json_body['id']}/revoke", headers: ui_headers
      end
      expect(mails.map(&:subject)).to eq(["PayHub: API key created", "PayHub: API key rolled", "PayHub: API key revoked"])
      expect(mails.map { |m| m.body.to_s }).to all(include("admin@example.com"))
    end

    it "TC-M12-2 member removed and role changed each email the owner" do
      member = create(:merchant_user, merchant:, role: "viewer", email: "member@example.com")
      mails = owner_mails do
        patch "/dashboard/api/members/#{member.id}", params: { role: "support" }.to_json, headers: ui_headers
        delete "/dashboard/api/members/#{member.id}", headers: ui_headers
      end
      expect(mails.map(&:subject)).to eq(["PayHub: Team member role changed", "PayHub: Team member removed"])
      expect(mails.map { |m| m.body.to_s }).to all(include("admin@example.com", "member@example.com"))
    end

    it "TC-M12-2 webhook URL and secret changes each email the owner" do
      mails = owner_mails do
        patch "/dashboard/api/webhook_endpoint", params: { url: "https://example.com/hooks" }.to_json, headers: ui_headers
        post "/dashboard/api/webhook_endpoint/roll_secret", headers: ui_headers
      end
      expect(mails.map(&:subject)).to eq(["PayHub: Webhook endpoint changed", "PayHub: Webhook secret rolled"])
      expect(mails.map { |m| m.body.to_s }).to all(include("admin@example.com"))
    end
  end

  describe "resetting a member's authenticator" do
    let(:developer) { create(:merchant_user, merchant:, role: "developer", email: "dev@example.com") }

    def reset(member) = post("/dashboard/api/members/#{member.id}/reset_otp", headers: ui_headers)

    it "TC-M12-3 clears the authenticator and recovery codes, ends sessions, emails both and audits" do
      RecoveryCode.regenerate!(developer)
      old_session = Session.create!(principal: developer, ip: "1.1.1.1", user_agent: "x")
      sign_in_as(admin, stepped_up: true)

      expect { reset(developer) }
        .to have_enqueued_mail(SecurityMailer, :otp_reset).once
        .and have_enqueued_mail(SecurityMailer, :account_changed).once

      expect(response).to have_http_status(:ok)
      expect([developer.reload.otp_enabled_at, developer.recovery_codes.to_a]).to eq([nil, []])
      expect(old_session.reload.revoked_at).to be_present
      expect(AuditEvent.last).to have_attributes(action: "team.otp_reset", target_id: developer.id)
    end

    it "TC-M12-3 the next sign-in answers next: enrol_otp, and enrolling issues a session" do
      sign_in_as(admin, stepped_up: true)
      reset(developer)
      reset! # a fresh browser (cookie jar) for the developer

      post "/dashboard/api/session", params: { email: developer.email, password: "correct horse battery staple" }.to_json,
                                     headers: ui_headers
      expect(json_body).to eq("next" => "enrol_otp")
      get "/dashboard/api/otp/setup"
      expect(response).to have_http_status(:ok)
      post "/dashboard/api/otp/confirm", params: { code: code_for(developer) }.to_json, headers: ui_headers
      expect(json_body["recovery_codes"].size).to eq(10)
      get "/dashboard/api/me"
      expect(json_body.dig("user", "id")).to eq(developer.id)
    end

    it "TC-M12-3 the old authenticator no longer works after a reset" do
      old_secret = developer.otp_secret
      sign_in_as(admin, stepped_up: true)
      reset(developer)
      expect(developer.reload.otp_secret).not_to eq(old_secret)
    end

    it "TC-M12-4 refuses the owner and yourself with 409, and needs step-up" do
      sign_in_as(admin, stepped_up: true)
      reset(owner)
      expect(response).to have_http_status(:conflict)
      reset(admin)
      expect(response).to have_http_status(:conflict)
      expect([owner.reload.otp_enabled_at, admin.reload.otp_enabled_at]).to all(be_present)

      sign_in_as(admin)
      reset(developer)
      expect(json_body.dig("error", "code")).to eq("step_up_required")
      expect(developer.reload.otp_enabled_at).to be_present
    end

    it "TC-M12-4 a developer cannot reset anyone (team.manage)" do
      sign_in_as(developer, stepped_up: true)
      reset(create(:merchant_user, merchant:, role: "viewer"))
      expect(response).to have_http_status(:forbidden)
    end
  end
end
