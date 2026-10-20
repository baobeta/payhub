# typed: true
# frozen_string_literal: true

module MemberSerializer
  extend T::Sig

  sig { params(user: MerchantUser).returns(T::Hash[String, T.untyped]) }
  def self.call(user)
    {
      "id" => user.id, "email" => user.email, "name" => user.name, "role" => user.role,
      "status" => status(user),
      "invitation_expires_at" => user.invitation_expires_at&.utc&.iso8601,
      "created_at" => user.created_at.utc.iso8601
    }
  end

  sig { params(user: MerchantUser).returns(String) }
  def self.status(user)
    if user.disabled_at then "removed"
    elsif user.pending_invitation? then "invited"
    else "active"
    end
  end
end
