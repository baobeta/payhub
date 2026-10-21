# typed: true
# frozen_string_literal: true

# Who may give whom which role. The permission check (team.manage) already
# ran; these are the record rules roles cannot express (design §3, layer 4).
module ChangeMemberRole
  extend T::Sig

  class Refused < StandardError; end

  sig { params(actor: MerchantUser, member: MerchantUser, role: String).returns(MerchantUser) }
  def self.call(actor:, member:, role:)
    raise Refused, "You cannot change your own role" if member.id == actor.id
    raise Refused, "The owner's role changes only through ownership transfer" if member.role == "owner" # authz-allow-role-check
    unless MerchantUser::INVITABLE_ROLES.include?(role)
      raise Refused, "Role must be one of #{MerchantUser::INVITABLE_ROLES.join(', ')}"
    end

    member.update!(role:)
    member
  end

  sig { params(actor: MerchantUser, member: MerchantUser).returns(MerchantUser) }
  def self.remove(actor:, member:)
    raise Refused, "You cannot remove yourself" if member.id == actor.id
    raise Refused, "The owner cannot be removed; transfer ownership first" if member.role == "owner" # authz-allow-role-check

    MerchantUser.transaction do
      member.update!(disabled_at: Time.current, invitation_digest: nil, otp_reset_digest: nil)
      member.revoke_sessions!
    end
    member
  end

  # M12 (Stripe's admin 2FA reset): a fresh secret, no recovery codes, every
  # session ended, and a single-use 72-hour token for the emailed link
  # (DECISIONS #25). Re-enrolling needs that token and the password, so the
  # password alone never reaches enrolment. The owner is never reset by
  # someone else: a sole owner's lost authenticator is a support-assisted flow
  # (out of scope). Returns [member, raw_token]; the token goes into the
  # email only.
  sig { params(actor: MerchantUser, member: MerchantUser).returns([MerchantUser, String]) }
  def self.reset_otp(actor:, member:)
    raise Refused, "You cannot reset your own authenticator" if member.id == actor.id
    raise Refused, "The owner's authenticator cannot be reset by another member" if member.role == "owner" # authz-allow-role-check
    raise Refused, "Only an active member who has signed in can be reset" unless member.active? && !member.pending_invitation?

    token = MerchantUser.transaction do
      member.update!(otp_secret: Otp.generate_secret, otp_enabled_at: nil, otp_last_used_step: nil)
      RecoveryCode.where(principal: member).delete_all
      member.revoke_sessions!
      member.issue_otp_reset_token!
    end
    [member, token]
  end
end
