# frozen_string_literal: true

class InvitationMailer < ApplicationMailer
  def invite(user, token)
    @merchant_name = user.merchant.name
    @role = user.role
    @url = app_url("/dashboard/invitations/#{token}")
    mail(to: user.email, subject: "You're invited to #{@merchant_name} on PayHub")
  end
end
