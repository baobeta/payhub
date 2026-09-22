# typed: strict
# frozen_string_literal: true

class EventSerializer
  extend T::Sig

  sig { params(event: OutboundEvent, include_attempts: T::Boolean).returns(T::Hash[String, T.untyped]) }
  def self.call(event, include_attempts: true)
    body = {
      "id" => event.id,
      "object" => "event",
      "type" => event.event_type,
      "state" => event.state,
      "payment_id" => event.payment_id,
      "attempts" => event.attempts,
      "next_attempt_at" => event.next_attempt_at.utc.iso8601(3),
      "delivered_at" => event.delivered_at&.utc&.iso8601(3),
      "last_error" => event.last_error,
      "data" => event.payload,
      "created_at" => event.created_at.utc.iso8601(3)
    }
    if include_attempts
      body["delivery_attempts"] = event.delivery_attempts.map do |a|
        { "attempt" => a.attempt_number, "response_status" => a.response_status, "error" => a.error,
          "duration_ms" => a.duration_ms, "at" => a.created_at.utc.iso8601(3) }
      end
    end
    body
  end
end
