# typed: true
# frozen_string_literal: true

# Who did what, to what, with what result (PCI DSS 10.2.2). Append-only in the
# database; kept 12 months. Never store request bodies, tokens or session ids.
class AuditEvent < ApplicationRecord
  RESULTS = %w[success denied failure].freeze

  validates :action, presence: true
  validates :result, inclusion: { in: RESULTS }

  def readonly? = persisted?

  def self.record!(action:, result:, actor: nil, actor_label: nil, merchant_id: nil, on_behalf_of_merchant_id: nil,
                   target: nil, ip: nil, user_agent: nil, request_id: nil, metadata: {})
    create!(action:, result:, actor_type: actor&.class&.name, actor_id: actor&.id, actor_label:,
            merchant_id:, on_behalf_of_merchant_id:, target_type: target&.class&.name, target_id: target&.id,
            ip:, user_agent: user_agent&.truncate(255), request_id:, metadata:)
  end
end
