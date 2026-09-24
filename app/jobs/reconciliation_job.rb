# typed: strict
# frozen_string_literal: true

# Daily reconciliation: the backstop for everything the real-time path and the
# minute-sweeper missed. It never fixes money; it finds discrepancies and
# makes them loud (ERROR log + metric) for a human.
#
#   1. Ledger integrity: any transfer whose legs do not net to zero.
#   2. Cache drift: payments.captured_minor (display cache) vs the ledger sum.
#   3. State drift: for each payment that moved money yesterday, ask the PSP
#      and compare its view of captured/refunded with ours.
#   4. Reservation drift: a pending refund must hold exactly its amount in
#      refunds_reserved, a settled one nothing (DECISIONS #16).
class ReconciliationJob < ApplicationJob
  extend T::Sig

  queue_as :sweepers

  sig { params(since: T.nilable(String)).void }
  def perform(since = nil)
    window_start = since ? Time.iso8601(since) : 1.day.ago
    report = { "unbalanced_transfers" => 0, "cache_drift" => 0, "psp_drift" => 0, "reservation_drift" => 0, "checked" => 0 }

    Ledger.unbalanced_transfer_ids.each do |transfer_id|
      report["unbalanced_transfers"] += 1
      Metrics.increment(:ledger_imbalance_detected)
      Rails.logger.error({ event: "reconciliation.unbalanced_transfer", transfer_id: transfer_id }.to_json)
    end

    Ledger.reservation_drift_refund_ids.each do |refund_id|
      report["reservation_drift"] += 1
      Rails.logger.error({ event: "reconciliation.reservation_drift", refund_id: refund_id }.to_json)
    end

    Payment.where(updated_at: window_start..).find_each do |payment|
      report["checked"] += 1
      ledger_captured = Ledger.captured_minor(payment)
      if payment.captured_minor != ledger_captured
        report["cache_drift"] += 1
        Rails.logger.error({ event: "reconciliation.cache_drift", payment_id: payment.id,
                             cached: payment.captured_minor, ledger: ledger_captured }.to_json)
      end
      compare_with_psp(payment, ledger_captured, report)
    end

    Rails.logger.info({ event: "reconciliation.done", window_start: window_start.utc.iso8601 }.merge(report).to_json)
  end

  private

  sig { params(payment: Payment, ledger_captured: Integer, report: T::Hash[String, Integer]).void }
  def compare_with_psp(payment, ledger_captured, report)
    return if %w[pending failed canceled].include?(payment.state) # nothing captured on either side

    result = PspRouter.adapter(payment.psp_name).fetch(payment.psp_reference)
    return if result.not_found?

    psp_captured = result.raw.fetch("captured_minor") { result.status == PspAdapter::Result::Status::Captured ? payment.amount_minor : 0 }.to_i
    return if psp_captured == ledger_captured

    report["psp_drift"] = report.fetch("psp_drift", 0) + 1
    Rails.logger.error({ event: "reconciliation.psp_drift", payment_id: payment.id, psp_name: payment.psp_name,
                         psp_captured_minor: psp_captured, ledger_captured_minor: ledger_captured }.to_json)
  rescue PspAdapter::TimedOut, PspAdapter::Unavailable => e
    Rails.logger.warn({ event: "reconciliation.psp_unreachable", payment_id: payment.id, detail: e.message }.to_json)
  end
end
