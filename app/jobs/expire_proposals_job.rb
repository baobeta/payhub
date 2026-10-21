# typed: strict
# frozen_string_literal: true

# N6 (DECISIONS #23): a proposal nobody decided within 14 days expires, as
# Stripe Approvals requests do. The facts it was based on have likely moved,
# so the maker resubmits rather than an approver acting on a stale picture.
#
# Each row is re-read under the same row lock DecideProposal takes, so an
# approval racing the job wins or loses cleanly: whichever commits first
# leaves the row non-pending, and the other refuses.
class ExpireProposalsJob < ApplicationJob
  extend T::Sig

  queue_as :sweepers

  TTL = T.let(14.days, ActiveSupport::Duration)
  BATCH = 500
  # TC-N6-5: batches repeat until none is left, up to this many per run (a
  # backlog bigger than that finishes on the next run).
  MAX_BATCHES = 100

  sig { void }
  def perform
    MAX_BATCHES.times do
      ids = OperatorProposal.open.where(created_at: ...TTL.ago).order(:created_at).limit(BATCH).pluck(:id)
      break if ids.empty?

      ids.each { |id| expire(id) }
    end
  end

  private

  sig { params(id: String).void }
  def expire(id)
    OperatorProposal.transaction do
      proposal = OperatorProposal.lock.find(id)
      next unless proposal.state == "pending"

      proposal.update!(state: "expired")
      AuditEvent.record!(action: "proposal.expired", result: "success", actor_label: "system", target: proposal,
                         merchant_id: T.must(proposal.payment).merchant_id, metadata: { "after_days" => TTL.in_days.to_i })
    end
  end
end
