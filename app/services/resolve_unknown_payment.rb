# typed: strict
# frozen_string_literal: true

# The read that collapses ambiguity. Given a payment whose PSP outcome we do
# not know, asks the PSP by OUR reference and returns a Result to apply — or
# nil when this attempt could not reach a verdict (the caller leaves the
# payment in `unknown`; the sweeper will try again).
#
# Used by AuthorizePaymentJob after a timeout and by the stuck-payment sweeper.
class ResolveUnknownPayment
  extend T::Sig

  sig { params(payment: Payment, adapter: PspAdapter).returns(T.nilable(PspAdapter::Result)) }
  def self.call(payment, adapter)
    result = adapter.fetch(payment.psp_reference)
    Metrics.increment(:psp_calls, psp: adapter.name, operation: "fetch", outcome: result.status.serialize)
    return result unless result.not_found?

    # 404: the PSP never saw our request. The ONLY case where re-sending the
    # authorize is safe — and only with the SAME psp_reference, so that if the
    # 404 was a lie (replica lag), the PSP's own idempotency catches it.
    adapter.authorize(payment)
  rescue PspAdapter::TimedOut => e
    Rails.logger.warn({ event: "resolve_unknown.timeout", payment_id: payment.id, detail: e.message }.to_json)
    nil
  end
end
