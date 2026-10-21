# typed: strict
# frozen_string_literal: true

# The asynchronous half of POST /v1/payments: call the PSP, apply the answer.
#
# Idempotent by construction — Sidekiq WILL re-run this after a crash. A
# second run against an already-resolved payment must be a no-op, never a
# second charge. The guards are: (1) the payment's state, (2) psp_reference
# sent as the PSP's idempotency key, (3) for a PSP with no idempotency
# (Kiripay), one POST per reference, ever: a rerun looks up instead of
# sending (DECISIONS #12), (4) transition! refusing illegal edges.
class AuthorizePaymentJob < ApplicationJob
  extend T::Sig

  queue_as :payments

  # Do NOT let Sidekiq retry blindly on a timeout: that is the double-charge
  # path. TimedOut is handled inside perform by moving to `unknown` and
  # fetching. Unavailable (5xx / connection refused) IS safe to retry with
  # the same reference, with backoff — for a PSP without idempotency the
  # retry becomes a lookup (see below), since a 5xx is no proof of nothing.
  retry_on PspAdapter::Unavailable, wait: :polynomially_longer, attempts: 5
  discard_on PspAdapter::Rejected # our bug; retrying cannot help — alert instead

  sig { params(payment_id: String).void }
  def perform(payment_id)
    payment = Payment.find(payment_id)
    return unless payment.state == "pending" # already resolved by a webhook, sweeper, or an earlier run

    adapter = PspRouter.adapter(payment.psp_name)

    # A PSP that does not deduplicate (DECISIONS #12): if this reference was
    # already sent — by an earlier run that got a 5xx or crashed before saving,
    # or by the sweeper — a second POST would be a second charge. Look it up.
    unless adapter.idempotent_authorize? || payment.claim_first_send!
      result = ResolveUnknownPayment.call(payment, adapter)
      ApplyPspResult.call(payment, result, source: "worker") if result
      return
    end

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
