# typed: true
# frozen_string_literal: true

# A maker-checker proposal as operators see it. `can` drives the buttons; the
# server re-checks under a row lock before applying (design §3).
module ProposalSerializer
  def self.call(proposal, viewer: nil)
    {
      "id" => proposal.id,
      "kind" => proposal.kind,
      "payment_id" => proposal.payment_id,
      "merchant" => T.must(proposal.payment).merchant.name,
      "payload" => proposal.payload,
      "reason_code" => proposal.reason_code,
      "reason_text" => proposal.reason_text,
      "case_reference" => proposal.case_reference,
      "state" => proposal.state,
      "proposed_by" => T.must(proposal.proposed_by).email,
      "decided_by" => proposal.decided_by&.email,
      "decision_note" => proposal.decision_note,
      "created_at" => proposal.created_at.utc.iso8601(3),
      "decided_at" => proposal.decided_at&.utc&.iso8601(3),
      "applied_at" => proposal.applied_at&.utc&.iso8601(3),
      "applied_transfer_id" => proposal.applied_transfer_id,
      "error" => proposal.error,
      "can" => can(proposal, viewer)
    }
  end

  def self.can(proposal, viewer)
    decide = !viewer.nil? && Permissions.granted?(:operator, viewer.role, "ops.proposals.decide")
    {
      "approve" => decide && proposal.approvable_by?(T.must(viewer)),
      "reject" => decide && proposal.approvable_by?(T.must(viewer)),
      "withdraw" => !viewer.nil? && proposal.proposed_by_id == viewer.id && proposal.state == "pending"
    }
  end
end
