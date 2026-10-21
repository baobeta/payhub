# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplyProposal do
  let(:maker) { create(:operator, role: "ops") }
  let(:approver) { create(:operator, role: "approver") }

  it "applies an unknown -> failed transition with provenance" do
    payment = create(:payment, state: "unknown")
    proposal = create(:operator_proposal, payment:, proposed_by: maker)

    described_class.call(proposal, approver:)

    expect(payment.reload.state).to eq("failed")
    transition = payment.transitions.order(:created_at).last
    expect(transition.source).to eq("operator")
    expect(transition.metadata).to include("proposal_id" => proposal.id, "proposed_by" => maker.email,
                                           "approved_by" => approver.email, "case_reference" => proposal.case_reference)
  end

  it "raises Stale when the payment has moved since the proposal was made" do
    payment = create(:payment, state: "unknown")
    proposal = create(:operator_proposal, payment:, proposed_by: maker)
    payment.transition!("authorized", sort_key: Time.current, source: "webhook")

    expect { described_class.call(proposal, approver:) }.to raise_error(ApplyProposal::Stale)
    expect(payment.reload.state).to eq("authorized")
  end

  it "posts a balanced ledger correction and records the transfer id" do
    proposal = create(:operator_proposal, :ledger_correction, proposed_by: maker)

    described_class.call(proposal, approver:)

    expect(proposal.reload.applied_transfer_id).to be_present
    expect(Ledger.unbalanced_transfer_ids).to be_empty
  end

  it "TC-N10-1: applying a payment_transition proposal writes exactly one outbound event for the new state" do
    payment = create(:payment, state: "unknown")
    proposal = create(:operator_proposal, payment:, proposed_by: maker)

    expect do
      described_class.call(proposal, approver:)
    end.to change(OutboundEvent, :count).by(1)

    event = OutboundEvent.order(:created_at).last
    expect(event.event_type).to eq("payment.failed")
    expect(event.payment_id).to eq(payment.id)
  end
end
