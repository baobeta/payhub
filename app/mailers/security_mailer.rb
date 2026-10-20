# typed: true
# frozen_string_literal: true

class SecurityMailer < ApplicationMailer
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

  sig { params(user: MerchantUser, from: String, to: String).void }
  def ownership_transferred(user, from:, to:)
    @from = from
    @to = to
    mail(to: user.email, subject: "PayHub account ownership was transferred")
  end
end
