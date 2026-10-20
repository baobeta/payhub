# typed: strict
# frozen_string_literal: true

# The read that collapses ambiguity. Given a payment whose PSP outcome we do
# not know, asks the PSP by OUR reference and returns a Result to apply — or
# nil when this attempt could not reach a verdict (the caller leaves the
# payment where it is; the sweeper will try again).
#
# Used by AuthorizePaymentJob after a timeout or a retry, and by the
# stuck-payment sweeper.
class ResolveUnknownPayment
  extend T::Sig

  # How long a PSP that does not deduplicate (Kiripay) may answer "not found"
  # for a reference we already sent before we stop waiting for it to appear
  # (replica lag) and fail the payment as never received (DECISIONS #12).
  LOOKUP_GRACE = T.let(30.minutes, ActiveSupport::Duration)

  sig { params(payment: Payment, adapter: PspAdapter).returns(T.nilable(PspAdapter::Result)) }
  def self.call(payment, adapter)
    result = adapter.fetch(payment.psp_reference)
    Metrics.increment(:psp_calls, psp: adapter.name, operation: "fetch", outcome: result.status.serialize)
    return result unless result.not_found?

    # 404. For a PSP that deduplicates by our reference (Nordpay), re-sending
    # with the SAME psp_reference is safe: if the 404 was a lie (replica lag),
    # the PSP's own idempotency returns the charge it already made.
    if adapter.idempotent_authorize?
      payment.mark_sent!
      return adapter.authorize(payment)
    end

    # A PSP that does not deduplicate gets one POST per reference, ever. Send
    # it only if nobody has (the worker died before its first call).
    return adapter.authorize(payment) if payment.claim_first_send!

    never_received(payment, result)
  rescue PspAdapter::TimedOut => e
    Rails.logger.warn({ event: "resolve_unknown.timeout", payment_id: payment.id, detail: e.message }.to_json)
    nil
  end

  # Sent, but the PSP says it has no such charge. Within LOOKUP_GRACE that may
  # be replica lag: no verdict, look again later. After it, the request never
  # landed, and the honest answer is a decline: the customer was not charged.
  sig { params(payment: Payment, not_found: PspAdapter::Result).returns(T.nilable(PspAdapter::Result)) }
  def self.never_received(payment, not_found)
    waited = Time.current - T.must(payment.first_sent_at)
    log = { payment_id: payment.id, psp_name: payment.psp_name, waited_s: waited.round }
    if waited < LOOKUP_GRACE
      Rails.logger.info(log.merge(event: "resolve_unknown.not_found_within_grace").to_json)
      return nil
    end

    Rails.logger.error(log.merge(event: "resolve_unknown.psp_never_received").to_json)
    Metrics.increment(:psp_never_received, psp: payment.psp_name)
    PspAdapter::Result.new(status: PspAdapter::Result::Status::Declined, psp_reference: not_found.psp_reference,
                           psp_charge_id: nil, decline_code: "psp_never_received", psp_timestamp: Time.current)
  end
  private_class_method :never_received
end
