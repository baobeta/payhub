# frozen_string_literal: true

require "rails_helper"

RSpec.describe DecideProposal do
  # Real threads, real connections: the row lock, not Ruby, must arbitrate.
  it "lets exactly one of two simultaneous approvers decide", :concurrency do
    maker = create(:operator, role: "ops")
    payment = create(:payment, state: "unknown")
    proposal = create(:operator_proposal, payment:, proposed_by: maker)
    approvers = [create(:operator, role: "approver"), create(:operator, role: "approver")]
    barrier = Concurrent::CyclicBarrier.new(approvers.size)
    outcomes = Concurrent::Array.new

    approvers.map do |approver|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          described_class.call(proposal.id, approver:, approve: true, note: nil)
          outcomes << :decided
        rescue ApiError => e
          outcomes << e.http_status
        end
      end
    end.each(&:join)

    expect(outcomes).to contain_exactly(:decided, 409)
    expect(proposal.reload.state).not_to eq("pending")
    expect(OperatorProposal.where(id: proposal.id, state: "applied").count).to eq(1)
  ensure
    # This example runs outside the rollback transaction; the around(:concurrency)
    # truncation does not cover operators, so remove what we created.
    if defined?(maker) && maker
      operator_ids = [maker.id, *approvers.map(&:id)]
      OperatorProposal.where(proposed_by_id: operator_ids).delete_all
      Operator.where(id: operator_ids).delete_all
    end
  end
end
