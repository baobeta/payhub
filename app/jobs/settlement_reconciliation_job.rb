# typed: strict
# frozen_string_literal: true

# Settlement-file reconciliation (DECISIONS #18). The daily ReconciliationJob
# asks the PSP's API what it *thinks* happened; this reads what it actually
# *paid out* — the settlement report — and holds our ledger to it.
#
# For each PSP that publishes a report, for one UTC day:
#   1. Ingest every line exactly once (unique on the PSP's line id).
#   2. Match it: a capture line to a payment, a refund line to a succeeded
#      refund of the same amount. A capture may not settle more than the
#      ledger captured — if it does, the PSP took money we never booked.
#   3. Matched → book it: psp_receivable is cleared, the fee and the payout
#      land in psp_fees and psp_payouts. Anything else is stored with its
#      problem, logged at ERROR and counted, and never booked.
#   4. Flag captures the PSP has not settled within SETTLE_WITHIN.
#
# It never fixes money. It finds the disagreement and makes it loud.
class SettlementReconciliationJob < ApplicationJob
  extend T::Sig

  queue_as :sweepers

  SETTLE_WITHIN = T.let(3.days, ActiveSupport::Duration)

  sig { params(date: T.nilable(String)).void }
  def perform(date = nil)
    day = date ? Date.iso8601(date) : Date.current.yesterday
    Payment::PSPS.each do |psp_name|
      lines = PspRouter.adapter(psp_name).settlement_report(day)
      next if lines.nil? # this PSP publishes no report

      report = Hash.new(0)
      lines.each { |line| report[ingest(psp_name, day, line)] += 1 }
      report["unsettled"] = flag_unsettled(psp_name)
      Rails.logger.info({ event: "settlement.reconciled", psp: psp_name, date: day.iso8601 }.merge(report).to_json)
    rescue PspAdapter::Unavailable, PspAdapter::TimedOut, PspAdapter::Rejected => e
      Rails.logger.error({ event: "settlement.report_unavailable", psp: psp_name, date: day.iso8601, detail: e.message }.to_json)
    end
  end

  private

  # Returns the line's status, or "duplicate" if it was ingested before.
  sig { params(psp_name: String, day: Date, report_line: PspAdapter::SettlementReportLine).returns(String) }
  def ingest(psp_name, day, report_line)
    SettlementLine.transaction do
      line = SettlementLine.create!(
        psp_name: psp_name, external_id: report_line.external_id, settled_on: day, kind: report_line.kind,
        psp_reference: report_line.psp_reference, refund_reference: report_line.refund_reference,
        gross_minor: report_line.gross_minor, fee_minor: report_line.fee_minor, net_minor: report_line.net_minor,
        currency: report_line.currency, booked_at: report_line.booked_at, status: "unmatched"
      )
      match(psp_name, line)
      line.status
    end
  rescue ActiveRecord::RecordNotUnique
    "duplicate"
  end

  sig { params(psp_name: String, line: SettlementLine).void }
  def match(psp_name, line)
    payment = Payment.find_by(psp_name: psp_name, psp_reference: line.psp_reference)
    return discrepancy!(line, "unmatched", "no payment with reference #{line.psp_reference}") unless payment
    return discrepancy!(line, "mismatch", "currency #{line.currency}, payment is #{payment.currency}", payment:) if line.currency != payment.currency

    problem = line.kind == "capture" ? capture_problem(line, payment) : refund_problem(line, payment)
    return discrepancy!(line, "mismatch", problem, payment:) if problem

    line.update!(payment: payment, status: "matched")
    Ledger.record_settlement!(line)
  end

  sig { params(line: SettlementLine, payment: Payment).returns(T.nilable(String)) }
  def capture_problem(line, payment)
    captured = Ledger.captured_minor(payment)
    settled = Ledger.settled_minor(payment)
    return if settled + line.gross_minor <= captured

    "settles #{line.gross_minor} on top of #{settled} already settled, but the ledger captured only #{captured}"
  end

  sig { params(line: SettlementLine, payment: Payment).returns(T.nilable(String)) }
  def refund_problem(line, payment)
    refund = payment.refunds.find_by(psp_reference: line.refund_reference.to_s)
    return "no refund with reference #{line.refund_reference.inspect} on this payment" unless refund

    line.refund = refund
    return "refund is #{refund.state} in our books" unless refund.state == "succeeded"
    return "refund is #{refund.amount_minor} in our books" unless refund.amount_minor == line.gross_minor

    nil
  end

  sig { params(line: SettlementLine, status: String, problem: String, payment: T.nilable(Payment)).void }
  def discrepancy!(line, status, problem, payment: nil)
    line.update!(status: status, problem: problem, payment: payment)
    Metrics.increment(:settlement_discrepancies, psp: line.psp_name, status: status)
    Rails.logger.error({ event: "settlement.discrepancy", psp: line.psp_name, line_id: line.external_id, status: status,
                         kind: line.kind, psp_reference: line.psp_reference, payment_id: payment&.id, problem: problem }.to_json)
  end

  # Captures the ledger booked more than SETTLE_WITHIN ago whose receivable
  # the PSP has still not cleared: money we believe we are owed and have not
  # been paid. Logged per payment; the count goes in the summary.
  sig { params(psp_name: String).returns(Integer) }
  def flag_unsettled(psp_name)
    receivable = LedgerEntry.joins(:account, :payment)
                            .where(ledger_accounts: { kind: "psp_receivable" }, payments: { psp_name: psp_name })
                            .group("ledger_entries.payment_id")
                            .having("MIN(ledger_entries.created_at) FILTER (WHERE ledger_entries.direction = 'debit') <= ?",
                                    SETTLE_WITHIN.ago)
                            .sum(Arel.sql("CASE ledger_entries.direction WHEN 'debit' THEN ledger_entries.amount_minor " \
                                          "ELSE -ledger_entries.amount_minor END"))
    unsettled = receivable.select { |_, outstanding| outstanding.to_i.positive? }
    unsettled.each do |payment_id, outstanding|
      Rails.logger.warn({ event: "settlement.unsettled_capture", psp: psp_name, payment_id: payment_id,
                          outstanding_minor: outstanding.to_i }.to_json)
    end
    unsettled.size
  end
end
