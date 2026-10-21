# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invitations and enrolment", type: :request do
  let(:admin) { create(:merchant_user, role: "admin") }

  def invite(email: "new@example.com", role: "support")
    post "/dashboard/api/invitations", params: { email:, role: }.to_json, headers: ui_headers
  end

  it "needs step-up to invite" do
    sign_in_as(admin)
    invite
    expect(json_body.dig("error", "code")).to eq("step_up_required")
  end

  it "invites, emails a link, and audits" do
    sign_in_as(admin, stepped_up: true)
    expect { invite }.to have_enqueued_mail(InvitationMailer, :invite)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("email" => "new@example.com", "status" => "invited")
    expect(AuditEvent.last).to have_attributes(action: "team.invited", merchant_id: admin.merchant_id)
  end

  it "refuses to invite an owner, and a viewer cannot invite at all" do
    sign_in_as(admin, stepped_up: true)
    invite(role: "owner")
    expect(response).to have_http_status(:unprocessable_content)

    sign_in_as(create(:merchant_user, merchant: admin.merchant, role: "viewer"), stepped_up: true)
    invite(email: "other@example.com")
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses a malformed email" do
    sign_in_as(admin, stepped_up: true)
    invite(email: "=cmd|' /C calc'!A0")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body.dig("error", "details", "email")).to be_present
  end

  it "refuses an email that already has an account" do
    sign_in_as(admin, stepped_up: true)
    invite(email: admin.email)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "accepts, enrols 2FA, returns recovery codes once, and signs in" do
    user, token = MerchantUser.invite!(merchant: admin.merchant, email: "new@example.com", role: "support", invited_by: admin)

    get "/dashboard/api/invitations/#{token}"
    expect(json_body).to include("email" => "new@example.com", "merchant_name" => admin.merchant.name)

    post "/dashboard/api/invitations/#{token}/accept",
         params: { name: "New", password: "a long enough password" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)

    get "/dashboard/api/otp/setup"
    expect(json_body["qr_svg"]).to include("<svg")

    post "/dashboard/api/otp/confirm", params: { code: ROTP::TOTP.new(user.reload.otp_secret).now }.to_json,
                                       headers: ui_headers
    expect(json_body["recovery_codes"].size).to eq(10)
    expect(user.reload).to have_attributes(otp_enabled?: true, invitation_digest: nil)

    get "/dashboard/api/me"
    expect(response).to have_http_status(:ok)
  end

  it "rejects a short password on acceptance" do
    _user, token = MerchantUser.invite!(merchant: admin.merchant, email: "short@example.com", role: "viewer", invited_by: admin)
    post "/dashboard/api/invitations/#{token}/accept", params: { name: "S", password: "short" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "cannot sign in with only a password before enrolling 2FA" do
    user, token = MerchantUser.invite!(merchant: admin.merchant, email: "half@example.com", role: "viewer", invited_by: admin)
    post "/dashboard/api/invitations/#{token}/accept", params: { name: "H", password: "a long enough password" }.to_json,
                                                       headers: ui_headers
    post "/dashboard/api/session", params: { email: user.email, password: "a long enough password" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
  end

  # M11: resend, revoke and re-invite (Stripe 10-day expiry; Slack resend and
  # deleted invites; GitHub re-inviting former members).
  describe "resend, revoke and re-invite" do
    let(:pending) { MerchantUser.invite!(merchant: admin.merchant, email: "pending@example.com", role: "viewer", invited_by: admin) }

    def resend(member) = post("/dashboard/api/invitations/#{member.id}/resend", headers: ui_headers)

    it "TC-M11-1 rotates the token: the old link dies, the new one works, the expiry resets, and it is emailed" do
      user, old_token = pending
      travel 3.days
      sign_in_as(admin, stepped_up: true)
      new_token = nil
      allow(InvitationMailer).to receive(:invite).and_wrap_original do |m, *args|
        new_token = args.last
        m.call(*args)
      end

      expect { resend(user) }.to have_enqueued_mail(InvitationMailer, :invite)

      expect(response).to have_http_status(:ok)
      expect(user.reload.invitation_expires_at).to be_within(1.minute).of(10.days.from_now)
      expect(AuditEvent.last).to have_attributes(action: "team.invitation_resent", target_id: user.id)
      get "/dashboard/api/invitations/#{old_token}"
      expect(response).to have_http_status(:not_found)
      get "/dashboard/api/invitations/#{new_token}"
      expect(response).to have_http_status(:ok)
    end

    it "TC-M11-1 needs team.manage with step-up" do
      user, = pending
      sign_in_as(admin)
      resend(user)
      expect(json_body.dig("error", "code")).to eq("step_up_required")
    end

    it "TC-M11-2 refuses an accepted member with 409 invalid_state" do
      sign_in_as(admin, stepped_up: true)
      resend(create(:merchant_user, merchant: admin.merchant, role: "viewer"))
      expect(response).to have_http_status(:conflict)
      expect(json_body.dig("error", "code")).to eq("invalid_state")
    end

    it "TC-M11-2 refuses the 6th resend within 24 hours with 429 resend_limit" do
      user, = pending
      sign_in_as(admin, stepped_up: true)
      5.times do
        resend(user)
        expect(response).to have_http_status(:ok)
      end
      resend(user)
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body.dig("error", "code")).to eq("resend_limit")
    end

    it "TC-M11-3 a removed pending invite's link is not found" do
      user, token = pending
      sign_in_as(admin, stepped_up: true)
      delete "/dashboard/api/members/#{user.id}", headers: ui_headers
      expect(response).to have_http_status(:ok)
      get "/dashboard/api/invitations/#{token}"
      expect(response).to have_http_status(:not_found)
      resend(user)
      expect(response).to have_http_status(:conflict)
    end

    it "TC-M11-4 a removed member's email can be invited again, in any case, as a new row" do
      former = create(:merchant_user, merchant: admin.merchant, email: "back@example.com", role: "viewer")
      sign_in_as(admin, stepped_up: true)
      delete "/dashboard/api/members/#{former.id}", headers: ui_headers
      before = former.reload.attributes

      invite(email: "Back@Example.com")

      expect(response).to have_http_status(:created)
      expect(json_body["id"]).not_to eq(former.id)
      expect(former.reload.attributes).to eq(before)
      expect(MerchantUser.where("lower(email) = ?", "back@example.com").count).to eq(2)
    end

    it "TC-M11-4 sign-in after a re-invite matches only the active row" do
      former = create(:merchant_user, merchant: admin.merchant, email: "back@example.com", role: "viewer")
      former.update!(disabled_at: Time.current)
      create(:merchant_user, merchant: admin.merchant, email: "back@example.com", role: "support",
                             password: "another long password")
      expect(SignIn.password(MerchantUser, email: "BACK@example.com", password: "another long password").status).to eq(:ok)
      expect(SignIn.password(MerchantUser, email: "back@example.com", password: "correct horse battery staple").status)
        .to eq(:invalid)
    end

    it "TC-M11-5 refuses an email that belongs to an active user of any merchant" do
      create(:merchant_user, email: "taken@example.com")
      sign_in_as(admin, stepped_up: true)
      invite(email: "TAKEN@example.com")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body.dig("error", "details", "email")).to eq(["already belongs to a PayHub user"])
    end
  end

  it "refuses an expired invitation" do
    _user, token = MerchantUser.invite!(merchant: admin.merchant, email: "late@example.com", role: "viewer", invited_by: admin)
    travel 11.days
    get "/dashboard/api/invitations/#{token}"
    expect(response).to have_http_status(:not_found)
  end
end
