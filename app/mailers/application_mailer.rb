# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "PayHub <no-reply@payhub.local>")
  layout "mailer"
end
