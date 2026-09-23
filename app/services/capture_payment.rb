# typed: strict
# frozen_string_literal: true

# POST /v1/payments/:id/capture — the synchronous half. Validates against the
# ledger under a row lock, then enqueues the PSP call. 202.
class CapturePayment
  extend T::Sig

  sig { params(payment: Payment, amount_minor: T.nilable(Integer)).returns(Payment) }
  def self.call(payment, amount_minor: nil)
    payment.with_lock do
      unless payment.state == "authorized"
        raise ApiError.invalid_request("Payment is #{payment.state}; only authorized payments can be captured",
                                       code: "invalid_state", param: "id")
      end

      already = Ledger.captured_minor(payment)
      remaining = payment.amount_minor - already
      amount = amount_minor || remaining

      if amount <= 0 || amount > remaining
        raise ApiError.validation("amount_minor" => ["must be between 1 and #{remaining} (authorized #{payment.amount_minor}, captured #{already})"])
      end

      adapter = PspRouter.adapter(payment.psp_name)
      if amount < remaining && !adapter.separate_authorize_and_capture?
        raise ApiError.invalid_request("#{payment.psp_name} does not support partial capture",
                                       code: "partial_capture_unsupported", param: "amount_minor")
      end

      # A capture request restarts the hold clock, so ExpireAuthorizationsJob
      # cannot void a payment whose capture job is still queued (DECISIONS #14).
      payment.touch
      CapturePaymentJob.perform_later(payment.id, amount)
    end
    payment
  end
end
