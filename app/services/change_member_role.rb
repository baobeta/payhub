# typed: true
# frozen_string_literal: true

# Who may give whom which role. The permission check (team.manage) already
# ran; these are the record rules roles cannot express (design §3, layer 4).
module ChangeMemberRole
  class Refused < StandardError; end

  def self.call(actor:, member:, role:)
    raise Refused, "You cannot change your own role" if member.id == actor.id
    raise Refused, "The owner's role changes only through ownership transfer" if member.role == "owner" # authz-allow-role-check
    unless MerchantUser::INVITABLE_ROLES.include?(role)
      raise Refused, "Role must be one of #{MerchantUser::INVITABLE_ROLES.join(', ')}"
    end

    member.update!(role:)
    member
  end

  def self.remove(actor:, member:)
    raise Refused, "You cannot remove yourself" if member.id == actor.id
    raise Refused, "The owner cannot be removed; transfer ownership first" if member.role == "owner" # authz-allow-role-check

    MerchantUser.transaction do
      member.update!(disabled_at: Time.current, invitation_digest: nil)
      member.revoke_sessions!
    end
    member
  end
end
