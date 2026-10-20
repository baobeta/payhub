# typed: true
# frozen_string_literal: true

class InvitationMailer < ApplicationMailer
  sig { params(user: MerchantUser, token: String).void }
  def invite(user, token)
    @merchant_name = T.must(user.merchant).name
    @role = user.role
    @url = app_url("/dashboard/invitations/#{token}")
    mail(to: user.email, subject: "You're invited to #{@merchant_name} on PayHub")
  end
end
