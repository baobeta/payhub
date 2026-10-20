# typed: true
# frozen_string_literal: true

# The `can` flags on a payment (design §3, "What the Vue app receives"):
# permission AND state machine AND money left. Only the server knows all three,
# so the UI never shows a button that would answer 409.
module PaymentActions
  extend T::Sig

  REFUNDABLE_STATES = %w[captured part_refunded].freeze

  sig { params(payment: Payment, granted: T.proc.params(arg0: String).returns(T::Boolean)).returns(T::Hash[String, T.untyped]) }
  def self.call(payment, granted:)
    authorized = payment.state == "authorized"
    captured = Ledger.captured_minor(payment)
    capturable = authorized ? payment.amount_minor - captured : 0
    refundable = refundable_minor(payment, captured)

    {
      "capture" => granted.call("payments.capture") && capturable.positive? && !payment.captures.pending.exists?,
      "cancel" => granted.call("payments.cancel") && authorized && PspRouter.adapter(payment.psp_name).supports_void?,
      "refund" => granted.call("payments.refund") && refundable.positive?,
      "capturable_minor" => capturable,
      "refundable_minor" => refundable
    }
  end

  sig { params(payment: Payment, captured: Integer).returns(Integer) }
  def self.refundable_minor(payment, captured)
    return 0 unless REFUNDABLE_STATES.include?(payment.state)

    captured - Ledger.refunded_minor(payment) - Ledger.reserved_minor(payment)
  end
end
