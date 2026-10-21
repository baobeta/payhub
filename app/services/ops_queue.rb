# typed: true
# frozen_string_literal: true

# O-01: exceptions go to a queue, never to a silent fix. Oldest first.
module OpsQueue
  extend T::Sig

  LIMIT = 50
  STUCK_PENDING_AFTER = 15.minutes

  sig { returns(T::Hash[String, T.untyped]) }
  def self.call
    {
      "unknown_payments" => Payment.where(state: "unknown").order(:updated_at).limit(LIMIT).includes(:merchant).map do |p|
        { "id" => p.id, "merchant" => T.must(p.merchant).name, "psp_name" => p.psp_name,
          "psp_reference" => p.psp_reference, "amount_minor" => p.amount_minor, "currency" => p.currency,
          "stuck_since" => p.updated_at.utc.iso8601, "check_attempts" => p.check_attempts }
      end,
      # C6/N13: still `pending` after 15 minutes, so neither the worker nor the
      # sweeper got an outcome. Never auto-failed on a timeout (Adyen, Primer);
      # a human looks. The sweeper's alert at the same age stays.
      "stuck_pending" => Payment.where(state: "pending", created_at: ...STUCK_PENDING_AFTER.ago)
                                .order(:created_at).limit(LIMIT).includes(:merchant).map do |p|
        { "id" => p.id, "merchant" => T.must(p.merchant).name, "psp_name" => p.psp_name,
          "psp_reference" => p.psp_reference, "amount_minor" => p.amount_minor, "currency" => p.currency,
          "pending_since" => p.created_at.utc.iso8601, "check_attempts" => p.check_attempts }
      end,
      # The PSP took the money after we failed the payment (TC-B3-3): a human refunds it.
      "late_successes" => late_successes.map do |p|
        { "id" => p.id, "merchant" => T.must(p.merchant).name, "psp_name" => p.psp_name,
          "psp_reference" => p.psp_reference, "amount_minor" => p.amount_minor, "currency" => p.currency,
          "failed_at" => p.updated_at.utc.iso8601 }
      end,
      "dead_events" => OutboundEvent.where(state: "dead").order(:updated_at).limit(LIMIT).includes(:merchant).map do |e|
        { "id" => e.id, "merchant" => T.must(e.merchant).name, "type" => e.event_type, "payment_id" => e.payment_id,
          "last_error" => e.last_error, "dead_since" => e.updated_at.utc.iso8601 }
      end,
      "reconciliation_breaks" => SettlementLine.where(status: %w[unmatched mismatch], reviewed_at: nil).count,
      "open_proposals" => OperatorProposal.open.count
    }
  end

  # Failed payments with a success webhook kept as an error: the customer was
  # charged after we failed the payment. Starts from those few events (partial
  # index idx_inbound_events_late_success), never from every failed payment.
  # They stay listed until someone refunds the customer at the PSP; PayHub has
  # no in-product path for that yet (USE_CASES §9, M-4), nor a "resolved" flag.
  sig { returns(T::Array[Payment]) }
  def self.late_successes
    flagged = InboundEvent.where("error LIKE ?", "#{ProcessInboundEventJob::LATE_SUCCESS}%")
                          .select(:psp_name, :psp_reference)
    Payment.where(state: "failed").where("(payments.psp_name, payments.psp_reference) IN (#{flagged.to_sql})")
           .order(:updated_at).limit(LIMIT).includes(:merchant).to_a
  end
end
