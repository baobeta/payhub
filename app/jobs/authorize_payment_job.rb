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

  # Do NOT let Sidekiq retry blindly on a Timeout: that is the double-charge
  # path. Timeout is handled inside perform by moving to `unknown` and
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
    # moment we sent the request, not the moment we gave up. The PSP cannot
    # have recorded the charge before receiving it, so any verdict it later
    # reports carries a timestamp >= sent_at and will apply rather than be
    # judged stale. (Dating `unknown` at give-up time made the PSP's real
    # timestamp look older than our own, and the poll result was discarded.)
    sent_at = Time.current

    result = begin
      adapter.authorize(payment)
    rescue PspAdapter::TimedOut => e
      # The request MAY have landed. Say so, then go and look.
      payment.transition!(:unknown, sort_key: sent_at, source: "worker",
                                    metadata: { "error" => e.message, "gave_up_at" => Time.current.utc.iso8601(3) })
      resolve_unknown(payment, adapter)
    end

    apply(payment, result) if result
  end

  private

  # The read that collapses ambiguity. Returns a Result to apply, or nil if
  # this run should stop (e.g. a retry was enqueued instead).
  sig { params(payment: Payment, adapter: PspAdapter).returns(T.nilable(PspAdapter::Result)) }
  def resolve_unknown(payment, adapter)
    result = adapter.fetch(payment.psp_reference)
    return result unless result.not_found?

    # 404: the PSP never saw our request. The ONLY case where re-sending the
    # authorize is safe — and only with the SAME psp_reference, so that if the
    # 404 was a lie (replica lag), the PSP's own idempotency catches it.
    adapter.authorize(payment)
  rescue PspAdapter::TimedOut
    # Still can't reach a verdict. Leave it in `unknown`; the sweeper (Phase 6)
    # will poll again and the 15-minute alert covers the rest.
    nil
  end

  # Map the PSP's answer onto the state machine. `T.absurd` makes the case
  # exhaustive: add a Status member without handling it here and srb tc fails.
  sig { params(payment: Payment, result: PspAdapter::Result).void }
  def apply(payment, result)
    meta = { "psp_charge_id" => result.psp_charge_id }
    ts = result.psp_timestamp
    status = result.status

    case status
    when PspAdapter::Result::Status::Authorized
      move(payment, :authorized, ts, meta)

    when PspAdapter::Result::Status::Captured
      # Nordpay captured in one call (capture_on_authorize). Our model has no
      # pending → captured edge, and that is correct: money was held before it
      # was taken, even if the PSP collapsed the two. Record both, with the
      # authorize 1ms earlier so the history reads in causal order.
      move(payment, :authorized, ts - 0.001, meta)
      move(payment, :captured, ts, meta.merge("captured_minor" => payment.amount_minor))

    when PspAdapter::Result::Status::Declined
      # HTTP 200 + declined: transport success, domain failure.
      move(payment, :failed, ts, meta.merge("decline_code" => result.decline_code))

    when PspAdapter::Result::Status::RequiresAction
      move(payment, :requires_action, ts, meta.merge("redirect_url" => result.redirect_url))

    when PspAdapter::Result::Status::NotFound
      # resolve_unknown already turned NotFound into a re-sent authorize, so
      # reaching here means a logic error, not a PSP condition. Fail loudly:
      # discard_on does not cover this, so Sidekiq retries and alerts.
      raise ArgumentError, "NotFound reached apply for payment #{payment.id}"

    else
      T.absurd(status)
    end
  end

  # A transition that tolerates being beaten to the same state by a webhook.
  #
  # Race: the guard in perform saw `pending`, then a webhook applied
  # `authorized` before we got here. transition!(:authorized) from
  # `authorized` is an illegal edge. But it is not an error — the payment IS
  # where we wanted it. Raising would make Sidekiq retry a job whose work is
  # done. So: if the illegal transition is a no-op in disguise, log and move
  # on; any OTHER illegal edge (e.g. authorized → pending) is a real bug and
  # propagates.
  sig do
    params(payment: Payment, to: Symbol, sort_key: T.any(Time, ActiveSupport::TimeWithZone),
           metadata: T::Hash[String, T.untyped]).void
  end
  def move(payment, to, sort_key, metadata)
    payment.transition!(to, sort_key: sort_key, source: "worker", metadata: metadata)
  rescue PaymentStateMachine::IllegalTransition => e
    raise unless payment.reload.state == to.to_s

    Rails.logger.info(
      { event: "authorize_job.already_in_state", payment_id: payment.id, state: to, detail: e.message }.to_json
    )
  end
end
