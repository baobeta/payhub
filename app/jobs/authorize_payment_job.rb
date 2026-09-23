# typed: strict
# frozen_string_literal: true

# The asynchronous half of POST /v1/payments: call the PSP, apply the answer.
#
# Idempotent by construction — Sidekiq WILL re-run this after a crash. A
# second run against an already-resolved payment must be a no-op, never a
# second charge. The guards are: (1) the payment's state, (2) psp_reference
# sent as the PSP's idempotency key, (3) transition! refusing illegal edges.
class AuthorizePaymentJob < ApplicationJob
  extend T::Sig

  queue_as :payments

  # Do NOT let Sidekiq retry blindly on a timeout: that is the double-charge
  # path. TimedOut is handled inside perform by moving to `unknown` and
  # fetching. Unavailable (5xx / connection refused) IS safe to retry with
  # the same reference, with backoff.
  retry_on PspAdapter::Unavailable, wait: :polynomially_longer, attempts: 5
  discard_on PspAdapter::Rejected # our bug; retrying cannot help — alert instead

  sig { params(payment_id: String).void }
  def perform(payment_id)
    payment = Payment.find(payment_id)
    return unless payment.state == "pending" # already resolved by a webhook, sweeper, or an earlier run

    adapter = PspRouter.adapter(payment.psp_name)

    # Captured BEFORE the call. If we time out, `unknown` is dated from the
    # moment the reference was FIRST sent — by this job or an earlier sender
    # (the sweeper re-sends after a 404) — not the moment we gave up, and not
    # this attempt's send. The PSP cannot have recorded the charge before first
    # receiving the reference, so any verdict it reports carries a timestamp
    # >= first_sent_at and applies rather than being judged stale (DECISIONS #11).
    sent_at = payment.mark_sent!

    result = begin
      adapter.authorize(payment)
    rescue PspAdapter::TimedOut => e
      # The request MAY have landed. Say so, then go and look.
      payment.transition!(:unknown, sort_key: sent_at, source: "worker",
                                    metadata: { "error" => e.message, "gave_up_at" => Time.current.utc.iso8601(3) })
      Metrics.increment(:psp_calls, psp: payment.psp_name, operation: "authorize", outcome: "timeout")
      ResolveUnknownPayment.call(payment, adapter)
    end

    ApplyPspResult.call(payment, result, source: "worker") if result
  end
end
