# typed: true
# frozen_string_literal: true

# A person on a merchant's team. Belongs to the LIVE merchant; the session's
# mode decides whether they read live data or the test twin's (design §2).
class MerchantUser < ApplicationRecord
  include TwoFactorPrincipal

  ROLES = %w[owner admin developer support viewer].freeze
  INVITABLE_ROLES = (ROLES - %w[owner]).freeze
  INVITATION_TTL = 10.days

  belongs_to :merchant
  belongs_to :invited_by, class_name: "MerchantUser", optional: true

  validates :role, inclusion: { in: ROLES }
  validate :merchant_is_live

  # Returns [user, raw_token]. The token goes into the email link only.
  def self.invite!(merchant:, email:, role:, invited_by:)
    raise ArgumentError, "owner cannot be invited; use ownership transfer" unless INVITABLE_ROLES.include?(role)

    token = SecureRandom.urlsafe_base64(32)
    user = create!(merchant:, email:, role:, invited_by:, invitation_digest: Digest::SHA256.hexdigest(token),
                   invitation_expires_at: INVITATION_TTL.from_now, otp_secret: Otp.generate_secret)
    [user, token]
  end

  private

  def merchant_is_live
    errors.add(:merchant, "must be the live merchant") unless merchant&.livemode
  end
end
