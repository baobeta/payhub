# typed: strict
# frozen_string_literal: true

# POST /v1/payments/:id/cancel — release an authorization. Synchronous:
# a void is idempotent at the PSP (voiding twice is harmless), so a timeout
# is resolved by a fetch and, failing that, the merchant may simply retry.
class CancelPayment
  extend T::Sig

  sig { params(payment: Payment).returns(Payment) }
  def self.call(payment)
    payment.with_lock do
      unless payment.state == "authorized"
        raise ApiError.invalid_request("Payment is #{payment.state}; only authorized payments can be canceled",
                                       code: "invalid_state", param: "id")
      end

      adapter = PspRouter.adapter(payment.psp_name)
      result = begin
        adapter.cancel(payment)
      rescue PspAdapter::TimedOut
        adapter.fetch(payment.psp_reference)
      end

      case result.status
      when PspAdapter::Result::Status::Canceled
        payment.transition!(:canceled, sort_key: result.psp_timestamp, source: "api",
                                       metadata: { "psp_charge_id" => result.psp_charge_id })
      when PspAdapter::Result::Status::Authorized
        # Still authorized after our attempt: the void never landed. Safe to retry.
        raise ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 503, code: "psp_unavailable",
                           message: "Cancel did not complete; retry", retriable: true)
      else
        raise ApiError.invalid_request("PSP reports charge is #{result.status.serialize}; cannot cancel",
                                       code: "invalid_state", param: "id")
      end
    end
    payment
  end
end
