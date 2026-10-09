# typed: true
# frozen_string_literal: true

# O-01: exceptions go to a queue, never to a silent fix. Oldest first.
module OpsQueue
  LIMIT = 50

  def self.call
    {
      "unknown_payments" => Payment.where(state: "unknown").order(:updated_at).limit(LIMIT).includes(:merchant).map do |p|
        { "id" => p.id, "merchant" => T.must(p.merchant).name, "psp_name" => p.psp_name,
          "psp_reference" => p.psp_reference, "amount_minor" => p.amount_minor, "currency" => p.currency,
          "stuck_since" => p.updated_at.utc.iso8601, "check_attempts" => p.check_attempts }
      end,
      "dead_events" => OutboundEvent.where(state: "dead").order(:updated_at).limit(LIMIT).includes(:merchant).map do |e|
        { "id" => e.id, "merchant" => T.must(e.merchant).name, "type" => e.event_type, "payment_id" => e.payment_id,
          "last_error" => e.last_error, "dead_since" => e.updated_at.utc.iso8601 }
      end,
      "reconciliation_breaks" => SettlementLine.where(status: %w[unmatched mismatch], reviewed_at: nil).count,
      "open_proposals" => OperatorProposal.open.count
    }
  end
end
