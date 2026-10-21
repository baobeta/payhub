# typed: strict
# frozen_string_literal: true

# Settlement-file reconciliation (DECISIONS #18). The daily ReconciliationJob
# asks the PSP's API what it *thinks* happened; this reads what it actually
# *paid out* — the settlement report — and holds our ledger to it.
#
# For each PSP that publishes a report, for one UTC day:
#   1. Ingest every line exactly once (unique on the PSP's line id).
#   2. Match it: the line must add up (net = gross − fee), then a capture
#      line to a payment, a refund line to a succeeded refund of the same
#      amount that no other line has settled. Captures may settle over several
#      lines (one per capture), but never more than the ledger captured — if
#      they do, the PSP took money we never booked.
#   3. Matched → book it: psp_receivable is cleared, the fee and the payout
#      land in psp_fees and psp_payouts. Anything else is stored with its
#      problem, logged at ERROR and counted, and never booked.
#   4. Flag captures the PSP has not settled within SETTLE_WITHIN.
#
# A PSP with no report skips 1-3, logs settlement.no_report, and still gets 4.
#
# It never fixes money. It finds the disagreement and makes it loud.
class SettlementReconciliationJob < ApplicationJob
  extend T::Sig

  queue_as :sweepers

  SETTLE_WITHIN = T.let(3.days, ActiveSupport::Duration)
  DETAIL_LIMIT = 20 # unsettled captures logged one by one per PSP per run

  sig { params(date: T.nilable(String)).void }
  def perform(date = nil)
    day = date ? Date.iso8601(date) : Date.current.yesterday
    Payment::PSPS.each do |psp_name|
      lines = PspRouter.adapter(psp_name).settlement_report(day)
      # A PSP that publishes no report (Kiripay) still owes us its captures:
      # with nothing to match, the receivable check is the whole reconciliation
      # (Stripe: reconcile from transaction history; DECISIONS #18, TEST_CASES J5).
      if lines.nil?
        Rails.logger.info({ event: "settlement.no_report", psp: psp_name, date: day.iso8601 }.to_json)
        lines = []
      end

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
    return "duplicate" if SettlementLine.exists?(psp_name: psp_name, external_id: report_line.external_id)

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
  rescue ActiveRecord::RecordNotUnique => e
    # Only the race the check above can't see: another run ingested this line
    # between the check and the insert. Any other conflict is a bug, not a duplicate.
    raise unless e.message.include?("index_settlement_lines_on_psp_name_and_external_id")

    "duplicate"
  rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
    # A line we cannot even store (a kind we don't model, such as a chargeback).
    # Make it loud and keep going: one odd line must not hide the rest of the
    # report, and every retry would stop at the same line (DECISIONS #18).
    Metrics.increment(:settlement_discrepancies, psp: psp_name, status: "unreadable")
    Rails.logger.error({ event: "settlement.line_unreadable", psp: psp_name, line_id: report_line.external_id,
                         kind: report_line.kind, detail: e.message }.to_json)
    "unreadable"
  end

  sig { params(psp_name: String, line: SettlementLine).void }
  def match(psp_name, line)
    payment = Payment.find_by(psp_name: psp_name, psp_reference: line.psp_reference)
    return discrepancy!(line, "unmatched", "no payment with reference #{line.psp_reference}") unless payment
    return discrepancy!(line, "mismatch", "currency #{line.currency}, payment is #{payment.currency}", payment:) if line.currency != payment.currency

    problem = arithmetic_problem(line) ||
              (line.kind == "capture" ? capture_problem(line, payment) : refund_problem(line, payment))
    return discrepancy!(line, "mismatch", problem, payment:) if problem

    line.update!(payment: payment, status: "matched")
    book!(line, payment)
  end

  # A booking the ledger refuses is a discrepancy on this line, never the end
  # of the run. The savepoint keeps the line (and the rest of the report)
  # when the insert itself fails.
  sig { params(line: SettlementLine, payment: Payment).void }
  def book!(line, payment)
    SettlementLine.transaction(requires_new: true) { Ledger.record_settlement!(line) }
  rescue Ledger::Unbalanced => e
    discrepancy!(line, "mismatch", "the ledger refused the booking: #{e.message}", payment:)
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?("idx_ledger_entries_refund_leg")

    # Two lines settling one refund at the same moment; refund_problem catches the sequential case.
    discrepancy!(line, "mismatch", "refund already settled by another line", payment:)
  end

  # The line must add up before anything else is believed: a capture pays out
  # gross less its fee, a refund takes back exactly its gross (no fee).
  sig { params(line: SettlementLine).returns(T.nilable(String)) }
  def arithmetic_problem(line)
    gross = line.gross_minor
    fee = line.fee_minor
    net = line.net_minor
    if line.kind == "capture"
      "net #{net} ≠ gross #{gross} − fee #{fee}" unless net == gross - fee
    elsif fee != 0 || net != -gross
      "refund net #{net} with fee #{fee}, expected net −#{gross} and no fee"
    end
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

    earlier = SettlementLine.where(refund: refund, status: "matched").where.not(id: line.id).pick(:external_id)
    return "refund already settled by #{earlier}" if earlier

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
    # A PSP with no report (Kiripay) never clears its receivable, so this list
    # only grows. Log the first few in detail and the size once, every run:
    # counts and exceptions per run, not one line per item forever.
    unsettled.to_a.take(DETAIL_LIMIT).each do |payment_id, outstanding|
      Rails.logger.warn({ event: "settlement.unsettled_capture", psp: psp_name, payment_id: payment_id,
                          outstanding_minor: outstanding.to_i }.to_json)
    end
    if unsettled.size > DETAIL_LIMIT
      Rails.logger.warn({ event: "settlement.unsettled_summary", psp: psp_name, count: unsettled.size,
                          detailed: DETAIL_LIMIT }.to_json)
    end
    unsettled.size
  end
end
