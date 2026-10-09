# typed: strict
# frozen_string_literal: true

# TOTP (RFC 6238) via rotp: 6 digits, 30-second steps, one step of drift.
module Otp
  extend T::Sig

  ISSUER = "PayHub"
  DRIFT_SECONDS = 30

  sig { returns(String) }
  def self.generate_secret = ROTP::Base32.random

  sig { params(secret: String, email: String).returns(String) }
  def self.provisioning_uri(secret, email) = ROTP::TOTP.new(secret, issuer: ISSUER).provisioning_uri(email)

  sig { params(uri: String).returns(String) }
  def self.qr_svg(uri) = RQRCode::QRCode.new(uri).as_svg(module_size: 4, use_path: true, viewbox: true)

  # The matched time step, or nil. Codes at or before `after_step` are refused.
  sig { params(secret: T.nilable(String), code: T.untyped, after_step: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def self.verify(secret, code, after_step: nil)
    return nil if secret.blank? || !code.to_s.match?(/\A\d{6}\z/)

    totp = ROTP::TOTP.new(secret)
    at = totp.verify(code.to_s, drift_behind: DRIFT_SECONDS, drift_ahead: DRIFT_SECONDS,
                                after: after_step && (after_step * totp.interval))
    at && (at / totp.interval)
  end
end
