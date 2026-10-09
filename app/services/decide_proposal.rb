# typed: true
# frozen_string_literal: true

# The maker-checker decision, under a row lock (design §3 layer 4). The guard
# is re-checked here even though the serializer already showed a `can` flag.
module DecideProposal
  def self.call(proposal_id, approver:, approve:, note:)
    proposal = OperatorProposal.transaction do
      locked = OperatorProposal.lock.find(proposal_id)
      unless locked.approvable_by?(approver)
        raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused",
                           message: "This proposal is not yours to decide (already decided, withdrawn, or your own)")
      end

      locked.update!(decided_by: approver, decided_at: Time.current, decision_note: note,
                     state: approve ? "applied" : "rejected")
      # A failed apply must roll back only the apply: the decision and the
      # `failed` state still commit.
      apply(locked, approver) if approve
      locked
    end
    proposal
  end

  def self.apply(proposal, approver)
    OperatorProposal.transaction(requires_new: true) { ApplyProposal.call(proposal, approver:) }
    proposal.update!(applied_at: Time.current)
  rescue ApplyProposal::Stale, PaymentStateMachine::IllegalTransition, Ledger::Unbalanced => e
    proposal.update!(state: "failed", error: e.message)
  end
end
