# typed: strict
# frozen_string_literal: true

# POST /v1/payments/:id/capture — the synchronous half. Validates against the
# ledger under a row lock, records the request as a Capture, then enqueues the
# PSP call. 202. One capture may be in flight per payment (DECISIONS #20); a
# second gets a retriable 409 until the first is settled.
#
# Several partial captures (DECISIONS #20, after Stripe's `final_capture` and
# Checkout.com's `capture_type`): a capture is final unless `final: false`.
# A non-final capture leaves the rest capturable from `captured` or
# `part_refunded`; a final one closes capturing. `amount_minor: 0, final: true`
# closes capturing without moving money: no PSP call, no Capture row.
class CapturePayment
  extend T::Sig

  # Stripe's limit: 50 non-final captures, then one final.
  MAX_NON_FINAL = 50

  sig { params(payment: Payment, amount_minor: T.nilable(Integer), final: T::Boolean).returns(Payment) }
  def self.call(payment, amount_minor: nil, final: true)
    payment.with_lock do
      unless Payment::CAPTURABLE_STATES.include?(payment.state)
        raise ApiError.invalid_request("Payment is #{payment.state}; only authorized or partly captured payments can be captured",
                                       code: "invalid_state", param: "id")
      end

      already = Ledger.captured_minor(payment)
      remaining = payment.capturable_minor(already)
      if remaining.zero?
        raise ApiError.invalid_request("The final capture has been made; nothing more can be captured",
                                       code: "capture_closed", param: "id")
      end

      adapter = PspRouter.adapter(payment.psp_name)
      if !final && !adapter.supports_multicapture?
        raise ApiError.invalid_request("#{payment.psp_name} does not support several partial captures",
                                       code: "multicapture_unsupported", param: "final")
      end

      amount = amount_minor || remaining
      if amount.zero? && final
        assert_none_in_flight!(payment)
        close_remainder!(payment, already)
        next
      end

      if amount <= 0 || amount > remaining
        raise ApiError.validation("amount_minor" => ["must be between 1 and #{remaining} (authorized #{payment.amount_minor}, captured #{already})"])
      end

      if amount < remaining && !adapter.separate_authorize_and_capture?
        raise ApiError.invalid_request("#{payment.psp_name} does not support partial capture",
                                       code: "partial_capture_unsupported", param: "amount_minor")
      end

      if !final && payment.captures.non_final.count >= MAX_NON_FINAL
        raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 422, code: "capture_limit_reached",
                           message: "At most #{MAX_NON_FINAL} non-final captures per payment; send a final capture",
                           param: "final")
      end

      assert_none_in_flight!(payment)
      capture =payment.captures.create!(amount_minor: amount, base_captured_minor: already, final: final)
      # A capture request restarts the hold clock, so ExpireAuthorizationsJob
      # cannot void a payment whose capture job is still queued (DECISIONS #14).
      payment.touch
      CapturePaymentJob.perform_later(capture.id)
    end
    payment
  end

  sig { params(payment: Payment).void }
  def self.assert_none_in_flight!(payment)
    return unless payment.captures.pending.exists?

    raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "capture_in_progress",
                       message: "A capture for this payment is still in flight; retry when it settles",
                       param: "id", retriable: true)
  end
  private_class_method :assert_none_in_flight!

  # A zero-amount final capture: stop capturing and keep what was taken. With
  # nothing captured there is nothing to keep; releasing the whole hold is
  # what cancel is for.
  sig { params(payment: Payment, already: Integer).void }
  def self.close_remainder!(payment, already)
    if already.zero?
      raise ApiError.invalid_request("Nothing has been captured; use cancel to release the hold", param: "amount_minor")
    end

    payment.close_captures!(reason: "merchant_request", source: "api")
  end
  private_class_method :close_remainder!
end
