# frozen_string_literal: true

# http://localhost:3000/rails/mailers/security_mailer (development only).
class SecurityMailerPreview < ActionMailer::Preview
  def new_sign_in = SecurityMailer.new_sign_in(user, ip: "203.0.113.9", user_agent: "Firefox on macOS")
  def sessions_revoked = SecurityMailer.sessions_revoked(user, count: 2)
  def password_changed = SecurityMailer.password_changed(user)
  def recovery_codes_regenerated = SecurityMailer.recovery_codes_regenerated(user)
  def recovery_code_used = SecurityMailer.recovery_code_used(user)
  def account_locked = SecurityMailer.account_locked(user, until_at: 30.minutes.from_now)
  def otp_reset = SecurityMailer.otp_reset(user, "preview-token")
  def ownership_transferred = SecurityMailer.ownership_transferred(user, from: "old@example.com", to: user.email)

  def account_changed
    SecurityMailer.account_changed(user, event: "api_key.revoked", actor: "dev@example.com", detail: "Checkout, live mode",
                                         at: Time.current)
  end

  private

  def user = MerchantUser.new(email: "owner@example.com", role: "owner")
end
