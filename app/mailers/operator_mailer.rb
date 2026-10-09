# frozen_string_literal: true

class OperatorMailer < ApplicationMailer
  def invite(operator, token)
    @url = app_url("/ops/invitations/#{token}")
    @role = operator.role
    mail(to: operator.email, subject: "Your PayHub operator account")
  end
end
