# typed: strict
# frozen_string_literal: true

# POST /v1/payments/:id/refunds — the synchronous half.
#
# THE over-refund guard (DECISIONS #6): lock the payment row FOR UPDATE, then
# compute what is refundable from the LEDGER — captured − refunded − reserved —
# then insert the refund row AND its reservation transfer (DECISIONS #16).
# Two concurrent requests serialize on the lock; the second sees the first's
# reservation in the ledger.
class CreateRefund
  extend T::Sig

  sig { params(payment: Payment, amount_minor: T.nilable(Integer), reason: T.nilable(String)).returns(Refund) }
  def self.call(payment, amount_minor: nil, reason: nil)
    refund = T.let(nil, T.nilable(Refund))

    payment.with_lock do
      unless %w[captured part_refunded].include?(payment.state)
        raise ApiError.invalid_request("Payment is #{payment.state}; only captured payments can be refunded",
                                       code: "invalid_state", param: "id")
      end

      captured = Ledger.captured_minor(payment)
      refunded = Ledger.refunded_minor(payment)
      reserved = Ledger.reserved_minor(payment)
      refundable = captured - refunded - reserved
      amount = amount_minor || refundable

      if amount <= 0 || amount > refundable
        raise ApiError.validation("amount_minor" => ["must be between 1 and #{refundable} " \
                                                     "(captured #{captured}, refunded #{refunded}, pending #{reserved})"])
      end

      adapter = PspRouter.adapter(payment.psp_name)
      if amount < captured && !adapter.supports_partial_refund?
        raise ApiError.invalid_request("#{payment.psp_name} supports full refunds only",
                                       code: "partial_refund_unsupported", param: "amount_minor")
      end

      refund = Refund.create!(
        payment: payment, amount_minor: amount, currency: payment.currency, reason: reason,
        psp_reference: Refund.generate_psp_reference # reserved BEFORE the PSP call, as for payments
      )
      Ledger.reserve_refund!(refund)
    end

    RefundPaymentJob.perform_later(T.must(refund).id)
    T.must(refund)
  end
end
