# typed: true
# frozen_string_literal: true

module MemberSerializer
  def self.call(user)
    {
      "id" => user.id, "email" => user.email, "name" => user.name, "role" => user.role,
      "status" => status(user),
      "invitation_expires_at" => user.invitation_expires_at&.utc&.iso8601,
      "created_at" => user.created_at.utc.iso8601
    }
  end

  def self.status(user)
    if user.disabled_at then "removed"
    elsif user.pending_invitation? then "invited"
    else "active"
    end
  end
end
