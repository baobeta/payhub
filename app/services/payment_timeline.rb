# typed: true
# frozen_string_literal: true

# M-04: one list of everything that happened to a payment, oldest first.
module PaymentTimeline
  def self.call(payment)
    entries = []
    payment.transitions.each do |t|
      entries << { "kind" => "transition", "at" => t.created_at, "from" => t.from_state, "to" => t.to_state,
                   "source" => t.source, "applied" => t.applied?, "metadata" => t.metadata }
    end
    payment.captures.order(:created_at).each do |c|
      entries << { "kind" => "capture", "at" => c.created_at, "amount_minor" => c.amount_minor, "state" => c.state,
                   "failure_code" => c.failure_code }
    end
    payment.refunds.order(:created_at).each do |r|
      entries << { "kind" => "refund", "at" => r.created_at, "id" => r.id, "amount_minor" => r.amount_minor,
                   "state" => r.state, "reason" => r.reason }
    end
    payment.ledger_entries.includes(:account).group_by(&:transfer_id).each do |transfer_id, legs|
      entries << { "kind" => "ledger_transfer", "at" => legs.map(&:created_at).min, "transfer_id" => transfer_id,
                   "legs" => legs.map do |l|
                     { "account" => l.account.kind, "direction" => l.direction, "amount_minor" => l.amount_minor }
                   end }
    end
    OutboundEvent.where(payment_id: payment.id).order(:created_at).each do |e|
      entries << { "kind" => "event", "at" => e.created_at, "id" => e.id, "type" => e.event_type, "state" => e.state,
                   "attempts" => e.attempts }
    end
    entries.sort_by { |e| e["at"] }.each { |e| e["at"] = e["at"].utc.iso8601(3) }
  end
end
