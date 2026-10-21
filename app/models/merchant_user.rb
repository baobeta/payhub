# typed: true
# frozen_string_literal: true

# A person on a merchant's team. Belongs to the LIVE merchant; the session's
# mode decides whether they read live data or the test twin's (design §2).
class MerchantUser < ApplicationRecord
  extend T::Sig
  include TwoFactorPrincipal

  ROLES = %w[owner admin developer support viewer].freeze
  INVITABLE_ROLES = (ROLES - %w[owner]).freeze
  INVITATION_TTL = 10.days
  OTP_RESET_TTL = 72.hours # the reset email's link (DECISIONS #25)

  belongs_to :merchant
  belongs_to :invited_by, class_name: "MerchantUser", optional: true

  validates :role, inclusion: { in: ROLES }
  validate :merchant_is_live

  # Returns [user, raw_token]. The token goes into the email link only.
  sig { params(merchant: Merchant, email: String, role: String, invited_by: T.nilable(MerchantUser)).returns([MerchantUser, String]) }
  def self.invite!(merchant:, email:, role:, invited_by:)
    raise ArgumentError, "owner cannot be invited; use ownership transfer" unless INVITABLE_ROLES.include?(role)

    token = SecureRandom.urlsafe_base64(32)
    user = create!(merchant:, email:, role:, invited_by:, invitation_digest: Digest::SHA256.hexdigest(token),
                   invitation_expires_at: INVITATION_TTL.from_now, otp_secret: Otp.generate_secret)
    [user, token]
  end

  # M11 resend: a new token kills the old link, and the 10 days start again
  # (Stripe's expiry; Slack's resend reactivates an invite).
  sig { returns(String) }
  def rotate_invitation!
    token = SecureRandom.urlsafe_base64(32)
    update!(invitation_digest: Digest::SHA256.hexdigest(token), invitation_expires_at: INVITATION_TTL.from_now)
    token
  end

  # M12 (DECISIONS #25): the single-use link an authenticator reset emails.
  # A new reset replaces any earlier token.
  sig { returns(String) }
  def issue_otp_reset_token!
    token = SecureRandom.urlsafe_base64(32)
    update!(otp_reset_digest: Digest::SHA256.hexdigest(token), otp_reset_expires_at: OTP_RESET_TTL.from_now)
    token
  end

  # True once per token, while unexpired: the conditional UPDATE is the
  # single-use check, so two sign-ins replaying one link cannot both pass.
  sig { params(token: String).returns(T::Boolean) }
  def consume_otp_reset_token!(token)
    return false if token.empty?

    MerchantUser.where(id:, otp_reset_digest: Digest::SHA256.hexdigest(token))
                .where("otp_reset_expires_at > ?", Time.current)
                .update_all(otp_reset_digest: nil, otp_reset_expires_at: nil) == 1
  end

  # The only other way an owner is created (invite! refuses owners): the very
  # first one, from `merchants:invite_owner` or the seed.
  sig { params(merchant: Merchant, email: String).returns([MerchantUser, String]) }
  def self.invite_first_owner!(merchant:, email:)
    if merchant.merchant_users.active.exists?(role: "owner") # authz-allow-role-check
      raise ArgumentError, "#{merchant.name} already has an owner"
    end

    token = SecureRandom.urlsafe_base64(32)
    user = create!(merchant:, email:, role: "owner", otp_secret: Otp.generate_secret,
                   invitation_digest: Digest::SHA256.hexdigest(token), invitation_expires_at: INVITATION_TTL.from_now)
    [user, token]
  end

  private

  sig { void }
  def merchant_is_live
    errors.add(:merchant, "must be the live merchant") unless merchant&.livemode
  end
end
