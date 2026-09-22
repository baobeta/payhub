# typed: strict
# frozen_string_literal: true

class RefundSerializer
  extend T::Sig

  sig { params(refund: Refund).returns(T::Hash[String, T.untyped]) }
  def self.call(refund)
    {
      "id" => refund.id,
      "object" => "refund",
      "payment_id" => refund.payment_id,
      "state" => refund.state,
      "amount_minor" => refund.amount_minor,
      "currency" => refund.currency,
      "display_amount" => Currency.to_display(refund.amount_minor, refund.currency),
      "reason" => refund.reason,
      "psp_reference" => refund.psp_reference,
      "created_at" => refund.created_at.utc.iso8601(3),
      "updated_at" => refund.updated_at.utc.iso8601(3)
    }
  end
end
