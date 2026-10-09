# typed: true
# frozen_string_literal: true

# Runs inside the approval transaction, after the proposal row is locked.
# Never forces: if the payment has moved since the proposal was made, the
# proposal fails and nothing changes (design §4).
module ApplyProposal
  class Stale < StandardError; end

  def self.call(proposal, approver:)
    case proposal.kind
    when "payment_transition" then transition(proposal, approver)
    when "ledger_correction" then correction(proposal, approver)
    end
  end

  def self.transition(proposal, approver)
    payment = proposal.payment
    payment.with_lock do
      allowed = OperatorProposal::ALLOWED_TRANSITIONS.fetch(payment.state, [])
      raise Stale, "payment is #{payment.state} now; propose again if still needed" unless allowed.include?(proposal.payload["to_state"])

      t = payment.transition!(proposal.payload.fetch("to_state"), sort_key: Time.current, source: "operator",
                              metadata: metadata(proposal, approver))
      raise Stale, "transition was not applied (a newer PSP event exists)" unless t.applied?
    end
  end

  def self.correction(proposal, approver)
    proposal.update!(applied_transfer_id: Ledger.record!(
      merchant: T.must(proposal.payment).merchant, currency: proposal.payload.fetch("currency"),
      legs: proposal.legs, payment: proposal.payment
    ))
  end

  def self.metadata(proposal, approver)
    { "proposal_id" => proposal.id, "proposed_by" => T.must(proposal.proposed_by).email,
      "approved_by" => approver.email, "reason_code" => proposal.reason_code,
      "reason" => proposal.reason_text, "case_reference" => proposal.case_reference }
  end
end
