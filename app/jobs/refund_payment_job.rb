# typed: strict
# frozen_string_literal: true

# Send a pending refund to the PSP and book the outcome.
#
# Idempotent: a refund row moves pending → succeeded|failed exactly once, and
# its ledger legs are written in the same transaction as that move. A re-run
# finds the row no longer pending and stops before touching the PSP.
class RefundPaymentJob < ApplicationJob
  extend T::Sig

  queue_as :payments

  retry_on PspAdapter::Unavailable, wait: :polynomially_longer, attempts: 5
  discard_on PspAdapter::Rejected

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
    end

    apply(refund, payment, result)
  end

  private

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
          Ledger.record_refund!(refund)
          refund.update!(state: "succeeded")
          to = Ledger.refunded_minor(payment) >= Ledger.captured_minor(payment) ? :refunded : :part_refunded
          # captured → part_refunded → refunded, or captured → refunded. Both drawn.
          payment.transition!(to, sort_key: result.psp_timestamp, source: "worker", metadata: meta) if payment.state != to.to_s
        end
      end

    when PspAdapter::RefundResult::Status::Failed
      refund.update!(state: "failed")
      Rails.logger.warn({ event: "refund.failed", refund_id: refund.id, code: result.failure_code }.to_json)

    when PspAdapter::RefundResult::Status::Pending, PspAdapter::RefundResult::Status::NotFound
      # Not resolved yet. Leave the row pending; its reservation still holds.
      nil

    else
      T.absurd(status)
    end
  end
end
