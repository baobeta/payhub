# typed: strict
# frozen_string_literal: true

# POST /v1/payments/:id/cancel — release an authorization. Synchronous:
# a void is idempotent at the PSP (voiding twice is harmless), so a timeout
# is resolved by a fetch and, failing that, the merchant may simply retry.
# ExpireAuthorizationsJob uses the same path for holds nobody captured.
class CancelPayment
  extend T::Sig

  sig { params(payment: Payment, source: String, reason: T.nilable(String)).returns(Payment) }
  def self.call(payment, source: "api", reason: nil)
    # Read the state under the lock, then release it before the HTTP call
    # (DECISIONS #13): a PSP call must not run inside a DB transaction, or its
    # psp_calls row is rolled back with the transaction.
    payment.with_lock { assert_authorized!(payment) }

    adapter = PspRouter.adapter(payment.psp_name)
    result = begin
      adapter.cancel(payment)
    rescue PspAdapter::TimedOut
      adapter.fetch(payment.psp_reference)
    end

    case result.status
    when PspAdapter::Result::Status::Canceled
      payment.with_lock do
        # Re-check under the lock: a capture may have landed while we were on
        # the wire. If so, cancel loses and changes nothing.
        assert_authorized!(payment)
        payment.transition!(:canceled, sort_key: result.psp_timestamp, source: source,
                                       metadata: { "psp_charge_id" => result.psp_charge_id,
                                                   "reason" => reason }.compact)
      end
    when PspAdapter::Result::Status::Authorized
      # Still authorized after our attempt: the void never landed. Safe to retry.
      raise ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 503, code: "psp_unavailable",
                         message: "Cancel did not complete; retry", retriable: true)
    else
      raise ApiError.invalid_request("PSP reports charge is #{result.status.serialize}; cannot cancel",
                                     code: "invalid_state", param: "id")
    end
    payment
  end

  # Call inside with_lock: state is then the freshest committed value.
  sig { params(payment: Payment).void }
  def self.assert_authorized!(payment)
    return if payment.state == "authorized"

    raise ApiError.invalid_request("Payment is #{payment.state}; only authorized payments can be canceled",
                                   code: "invalid_state", param: "id")
  end
end
