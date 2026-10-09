# typed: true
# frozen_string_literal: true

# Never the secret or its digest: prefix and last 4 identify a key.
module ApiKeySerializer
  def self.call(key)
    {
      "id" => key.id, "name" => key.name, "note" => key.note, "livemode" => key.livemode,
      "redacted" => "#{key.prefix}…#{key.last4 || '????'}", "status" => key.status,
      "created_by" => key.created_by&.email,
      "created_at" => key.created_at.utc.iso8601, "last_used_at" => key.last_used_at&.utc&.iso8601,
      "expires_at" => key.expires_at&.utc&.iso8601, "revoked_at" => key.revoked_at&.utc&.iso8601
    }
  end
end
