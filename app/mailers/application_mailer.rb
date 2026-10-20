# typed: true
# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  extend T::Sig

  default from: ENV.fetch("MAIL_FROM", "PayHub <no-reply@payhub.local>")
  layout "mailer"

  private

  # Absolute link into the UI, built from default_url_options (there is no
  # Rails route for Vue paths).
  sig { params(path: String).returns(String) }
  def app_url(path)
    options = Rails.application.config.action_mailer.default_url_options || {}
    port = options[:port] ? ":#{options[:port]}" : ""
    "#{options[:protocol] || 'http'}://#{options.fetch(:host, 'localhost')}#{port}#{path}"
  end
end
