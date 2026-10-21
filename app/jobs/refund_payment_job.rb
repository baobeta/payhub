# typed: strict
# frozen_string_literal: true

# Send a pending refund to the PSP and book the outcome.
#
# Idempotent: a refund row moves pending → succeeded|failed exactly once, and
# its reservation is posted or voided in the same transaction as that move
# (DECISIONS #16). The unique refund-leg index refuses a second settlement. A re-run
# finds the row no longer pending and stops before touching the PSP.
class RefundPaymentJob < ApplicationJob
  extend T::Sig

  queue_as :payments

  retry_on PspAdapter::Unavailable, wait: :polynomially_longer, attempts: 5

  sig { params(refund_id: String).void }
  def perform(refund_id)
    refund = Refund.find(refund_id)
    return unless refund.state == "pending"

    payment = T.must(refund.payment)
    adapter = PspRouter.adapter(payment.psp_name)

    result = begin
      adapter.refund(refund)
    rescue PspAdapter::TimedOut
      # Same rule as charges: never re-send a write we can't confirm. Look it up
      # by OUR reference. NotFound here means it never landed; the sweeper
      # (Phase 6) re-drives pending refunds, so we just leave it pending.
      adapter.fetch_refund(refund.psp_reference)
    rescue PspAdapter::Rejected => e
      rejected(refund, adapter, e)
    end

    apply(refund, payment, result) if result
  end

  private

  # A refusal is final only once a read confirms the refund never landed. A
  # re-run's POST is refused when an earlier POST already refunded (Kiripay has
  # no idempotency key: 409 already_refunded); failing that would void the
  # reservation while the customer holds the money — paid twice (DECISIONS #16).
  # A 2xx we could not parse (Rejected 200) is not a refusal at all: the PSP
  # took it. Leave it pending, reservation held, and shout.
  sig do
    params(refund: Refund, adapter: PspAdapter, error: PspAdapter::Rejected)
      .returns(T.nilable(PspAdapter::RefundResult))
  end
  def rejected(refund, adapter, error)
    unless error.http_status.between?(400, 499)
      Rails.logger.error({ event: "refund.unreadable_response", refund_id: refund.id, detail: error.message }.to_json)
      return nil
    end

    confirmed = adapter.fetch_refund(refund.psp_reference)
    return confirmed if confirmed.status == PspAdapter::RefundResult::Status::Succeeded

    PspAdapter::RefundResult.new(status: PspAdapter::RefundResult::Status::Failed, psp_reference: refund.psp_reference,
                                 psp_refund_id: nil, failure_code: "psp_rejected_#{error.http_status}",
                                 psp_timestamp: Time.current)
  end

  sig { params(refund: Refund, payment: Payment, result: PspAdapter::RefundResult).void }
  def apply(refund, payment, result)
    status = result.status
    meta = { "psp_refund_id" => result.psp_refund_id }

    case status
    when PspAdapter::RefundResult::Status::Succeeded
      payment.with_lock do
        refund.reload
        next unless refund.state == "pending" # a concurrent run got here first

        Refund.transaction do
          Ledger.post_refund!(refund)
          refund.update!(state: "succeeded")
          captured = Ledger.captured_minor(payment)
          # Terminal only once nothing more can be captured either: while
          # capturing is open, refunding all of it so far is still part_refunded
          # (DECISIONS #20; Payment#close_captures! finishes the job).
          closed = payment.capturable_minor(captured).zero?
          to = closed && Ledger.refunded_minor(payment) >= captured ? :refunded : :part_refunded
          # captured → part_refunded → refunded, or captured → refunded. Both drawn.
          payment.transition!(to, sort_key: result.psp_timestamp, source: "worker", metadata: meta) if payment.state != to.to_s
          OutboundEvent.emit!(payment, "refund.succeeded", "refund" => RefundSerializer.call(refund))
        end
      end

    when PspAdapter::RefundResult::Status::Failed
      payment.with_lock do
        refund.reload
        next unless refund.state == "pending" # a concurrent run got here first

        Refund.transaction do
          Ledger.void_refund!(refund) # the reservation goes back to the merchant
          refund.update!(state: "failed")
          OutboundEvent.emit!(payment, "refund.failed", "refund" => RefundSerializer.call(refund),
                                                        "failure_code" => result.failure_code)
        end
      end
      Rails.logger.warn({ event: "refund.failed", refund_id: refund.id, code: result.failure_code }.to_json)

    when PspAdapter::RefundResult::Status::Pending, PspAdapter::RefundResult::Status::NotFound
      # Not resolved yet. Leave the row pending; its ledger reservation still holds.
      nil

    else
      T.absurd(status)
    end
  end
end
