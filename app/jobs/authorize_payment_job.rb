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

    result = begin
      adapter.authorize(payment)
    rescue PspAdapter::TimedOut => e
      # The request MAY have landed. Say so, then go and look.
      payment.transition!(:unknown, sort_key: Time.current, source: "worker", metadata: { "error" => e.message })
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

  # ───────────────────────────────────────────────────────────────────────────
  # TODO(you): map the PSP's answer onto the state machine.
  #
  # `result.status` is a PspAdapter::Result::Status (a T::Enum). Sorbet checks
  # that every member is handled — leave one out and `srb tc` fails.
  #
  # Rules to encode:
  #   Authorized     → transition!(:authorized, ...)
  #                    If the merchant asked for capture-on-authorize, Nordpay
  #                    has already captured; what state is that? Check
  #                    `payment.capture_on_authorize` and `result.status`.
  #   Captured       → transition!(:captured, ...)  — but only if the machine
  #                    allows pending → captured. It doesn't (see the diagram).
  #                    Which two transitions get you there honestly?
  #   Declined       → transition!(:failed, ...) with the decline_code in metadata
  #   RequiresAction → transition!(:requires_action, ...)  (Kiripay, Phase 7)
  #   NotFound       → cannot happen here; resolve_unknown already re-sent.
  #                    What should the job do if it does? (Hint: raise.)
  #
  # Every transition! call needs:
  #   sort_key: result.psp_timestamp    ← the PSP's clock, not ours
  #   source:   "worker"
  #   metadata: something useful for the 3am runbook (psp_charge_id at least)
  #
  # Two things to remember from the state machine:
  #   * transition! raises IllegalTransition if the edge doesn't exist, and
  #     records-without-applying if sort_key is stale. Neither is your job's
  #     problem to work around — they are the invariants doing their job.
  #   * If `payment.state` is no longer "pending" by the time you get here
  #     (a webhook beat you), transition! will tell you. Decide: rescue and
  #     log, or let it raise? Think about what Sidekiq does with a raise.
  # ───────────────────────────────────────────────────────────────────────────
  sig { params(payment: Payment, result: PspAdapter::Result).void }
  def apply(payment, result)
    raise NotImplementedError, "TODO(you): see comment above"
  end
end
