# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorProposal do
  let(:maker) { create(:operator, role: "ops") }
  let(:checker) { create(:operator, role: "approver") }
  let(:payment) { create(:payment).tap { |p| p.update_columns(state: "unknown") } } # rubocop:disable Rails/SkipsModelValidations

  it "refuses self-approval in the database" do
    proposal = create(:operator_proposal, payment:, proposed_by: maker)
    # decided_at is set too, so `chk_operator_proposals_decided_shape` is satisfied
    # and only the self-approval constraint can be the one that fires.
    expect { described_class.where(id: proposal.id).update_all(decided_by_id: maker.id, decided_at: Time.current, state: "rejected") }
      .to raise_error(ActiveRecord::StatementInvalid, /chk_operator_proposals_not_self/)
  end

  it "never lets the payload change after submission, even bypassing Rails" do
    proposal = create(:operator_proposal, payment:, proposed_by: maker)
    expect { described_class.where(id: proposal.id).update_all(payload: { "to_state" => "authorized" }) }
      .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
  end

  it "accepts only transitions out of unknown that the state machine allows" do
    expect(build(:operator_proposal, payment:, proposed_by: maker, payload: { "to_state" => "captured" })).not_to be_valid
    expect(build(:operator_proposal, payment:, proposed_by: maker, payload: { "to_state" => "failed" })).to be_valid
  end

  it "accepts a ledger correction only when its legs balance" do
    unbalanced = { "currency" => "EUR", "legs" => [{ "account_kind" => "merchant_payable", "direction" => "credit", "amount_minor" => 5 }] }
    expect(build(:operator_proposal, :ledger_correction, payment:, proposed_by: maker, payload: unbalanced)).not_to be_valid
  end

  it "requires a reason code and a case reference" do
    expect(build(:operator_proposal, payment:, proposed_by: maker, reason_code: nil)).not_to be_valid
    expect(build(:operator_proposal, payment:, proposed_by: maker, case_reference: "")).not_to be_valid
  end

  describe "#approvable_by?" do
    it "is false for the proposer whatever their role" do
      proposal = create(:operator_proposal, payment:, proposed_by: maker)
      maker.update!(role: "approver")
      expect(proposal.approvable_by?(maker)).to be(false)
    end

    it "is true for another active approver while pending" do
      proposal = create(:operator_proposal, payment:, proposed_by: maker)
      expect(proposal.approvable_by?(checker)).to be(true)
    end

    it "is false once decided, withdrawn or failed" do
      proposal = create(:operator_proposal, payment:, proposed_by: maker)
      proposal.update_columns(state: "withdrawn")
      expect(proposal.approvable_by?(checker)).to be(false)

      proposal.update_columns(state: "failed", decided_by_id: checker.id, decided_at: Time.current)
      expect(proposal.approvable_by?(checker)).to be(false)
    end

    it "is false for a disabled operator" do
      proposal = create(:operator_proposal, payment:, proposed_by: maker)
      checker.update!(disabled_at: Time.current)
      expect(proposal.approvable_by?(checker)).to be(false)
    end
  end
end
