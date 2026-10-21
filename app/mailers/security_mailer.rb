# typed: true
# frozen_string_literal: true

# Security notices. The person hears about every change to how they sign in
# (NIST 800-63B §4.1.2.1 / §4.2), and the owner hears about every change to
# the account's keys, endpoint and team, with who made it (M12; Stripe).
class SecurityMailer < ApplicationMailer
  # The owner notice for each audited change: [subject, what the actor did].
  ACCOUNT_CHANGES = T.let(
    {
      "api_key.created" => ["API key created", "created an API key"],
      "api_key.rolled" => ["API key rolled", "rolled an API key"],
      "api_key.revoked" => ["API key revoked", "revoked an API key"],
      "team.invited" => ["Team member invited", "invited a team member"],
      "team.removed" => ["Team member removed", "removed a team member"],
      "team.role_changed" => ["Team member role changed", "changed a team member's role"],
      "team.otp_reset" => ["Team member's authenticator reset", "reset a team member's authenticator"],
      "webhook.endpoint_updated" => ["Webhook endpoint changed", "changed the webhook endpoint"],
      "webhook.secret_rolled" => ["Webhook secret rolled", "rolled the webhook signing secret"]
    }.freeze,
    T::Hash[String, [String, String]]
  )

  sig do
    params(
      principal: T.any(MerchantUser, Operator),
      ip: T.nilable(String),
      user_agent: T.nilable(String)
    ).void
  end
  def new_sign_in(principal, ip:, user_agent:)
    @ip = ip
    @user_agent = user_agent
    @at = Time.current
    mail(to: principal.email, subject: "New sign-in to PayHub")
  end

  # M7: "sign out all other sessions" ended `count` sessions.
  sig { params(principal: T.any(MerchantUser, Operator), count: Integer).void }
  def sessions_revoked(principal, count:)
    @count = count
    mail(to: principal.email, subject: "Your other PayHub sessions were signed out")
  end

  sig { params(principal: T.any(MerchantUser, Operator)).void }
  def password_changed(principal)
    mail(to: principal.email, subject: "Your PayHub password was changed")
  end

  sig { params(principal: T.any(MerchantUser, Operator)).void }
  def recovery_codes_regenerated(principal)
    mail(to: principal.email, subject: "New PayHub recovery codes were generated")
  end

  sig { params(principal: T.any(MerchantUser, Operator)).void }
  def recovery_code_used(principal)
    mail(to: principal.email, subject: "A PayHub recovery code was used")
  end

  sig { params(principal: T.any(MerchantUser, Operator), until_at: T.any(Time, ActiveSupport::TimeWithZone)).void }
  def account_locked(principal, until_at:)
    @until_at = until_at
    mail(to: principal.email, subject: "Your PayHub account is locked")
  end

  # DECISIONS #25: the link carries the single-use reset token (Stripe).
  sig { params(user: MerchantUser, token: String).void }
  def otp_reset(user, token)
    @url = app_url("/dashboard/reset-authenticator?token=#{token}")
    @hours = (MerchantUser::OTP_RESET_TTL / 1.hour).to_i
    mail(to: user.email, subject: "Your PayHub authenticator was reset")
  end

  # To the owner. `actor` is an email: the record may be gone by delivery.
  # `at` is when the change happened; the job may run much later (TC-M12-6).
  sig do
    params(owner: MerchantUser, event: String, actor: String, at: T.any(Time, ActiveSupport::TimeWithZone),
           detail: T.nilable(String)).void
  end
  def account_changed(owner, event:, actor:, at:, detail: nil)
    subject, @did = ACCOUNT_CHANGES.fetch(event)
    @actor = actor
    @at = at
    @detail = detail
    mail(to: owner.email, subject: "PayHub: #{subject}")
  end

  sig { params(user: MerchantUser, from: String, to: String).void }
  def ownership_transferred(user, from:, to:)
    @from = from
    @to = to
    mail(to: user.email, subject: "PayHub account ownership was transferred")
  end
end
