# typed: strict
# frozen_string_literal: true

# The merchant-facing shape of a payment. Amounts stay in minor units with
# the currency beside them; `display_amount` is a convenience, never the truth.
class PaymentSerializer
  extend T::Sig

  sig { params(payment: Payment, include_transitions: T::Boolean).returns(T::Hash[String, T.untyped]) }
  def self.call(payment, include_transitions: false)
    body = {
      "id" => payment.id,
      "object" => "payment",
      "state" => payment.state,
      "amount_minor" => payment.amount_minor,
      "currency" => payment.currency,
      "display_amount" => payment.display_amount,
      "captured_minor" => payment.captured_minor,
      "psp_name" => payment.psp_name,
      "psp_reference" => payment.psp_reference,
      "merchant_currency" => payment.merchant_currency,
      "fx_rate" => payment.fx_rate.to_s,
      "metadata" => payment.metadata,
      "created_at" => payment.created_at.utc.iso8601(3),
      "updated_at" => payment.updated_at.utc.iso8601(3)
    }
    if include_transitions
      body["transitions"] = payment.transitions.map do |t|
        {
          "from" => t.from_state, "to" => t.to_state, "source" => t.source,
          "psp_timestamp" => t.sort_key.utc.iso8601(3), "received_at" => t.created_at.utc.iso8601(3),
          "applied" => t.applied?, "metadata" => t.metadata
        }
      end
    end
    body
  end
end
