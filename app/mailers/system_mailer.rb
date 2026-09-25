# frozen_string_literal: true

# Proves the mail path end to end. Real mailers (invitations, security alerts,
# proposals awaiting approval) arrive in phases 1 and 2.
class SystemMailer < ApplicationMailer
  def smoke(to)
    mail(to:, subject: "PayHub mail is working")
  end
end
