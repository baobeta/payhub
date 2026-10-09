# typed: true
# frozen_string_literal: true

# PayHub staff. Separate from MerchantUser: different cookie, different
# permissions, and nothing a merchant can ever grant.
class Operator < ApplicationRecord
  include TwoFactorPrincipal

  ROLES = %w[support ops approver admin].freeze
  INVITATION_TTL = 3.days

  belongs_to :invited_by, class_name: "Operator", optional: true
  validates :role, inclusion: { in: ROLES }

  def self.invite!(email:, role:, invited_by:)
    raise ArgumentError, "unknown operator role #{role.inspect}" unless ROLES.include?(role)

    token = SecureRandom.urlsafe_base64(32)
    op = create!(email:, role:, invited_by:, invitation_digest: Digest::SHA256.hexdigest(token),
                 invitation_expires_at: INVITATION_TTL.from_now, otp_secret: Otp.generate_secret)
    [op, token]
  end
end
