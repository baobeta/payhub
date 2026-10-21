# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExpireProposalsJob do
  let(:maker) { create(:operator, role: "ops") }
  let(:approver) { create(:operator, role: "approver") }

  def proposal_created(ago)
    create(:operator_proposal, payment: create(:payment, state: "unknown"), proposed_by: maker).tap do |p|
      p.update_columns(created_at: ago.ago) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  it "TC-N6-3: expires a pending proposal after 14 days, audits it, and approving it then gets 409" do
    stale = proposal_created(15.days)
    fresh = proposal_created(13.days)

    described_class.perform_now

    expect(stale.reload.state).to eq("expired")
    expect(fresh.reload.state).to eq("pending")
    audit = AuditEvent.find_by!(action: "proposal.expired", target_id: stale.id)
    expect(audit).to have_attributes(actor_type: nil, actor_label: "system", result: "success",
                                     merchant_id: stale.payment.merchant_id)
    expect { DecideProposal.call(stale.id, approver:, approve: true, note: nil) }
      .to raise_error(ApiError) { |e| expect(e.http_status).to eq(409) }
  end

  it "TC-N6-3: leaves decided proposals alone and is a no-op the second time" do
    old = proposal_created(20.days)
    old.update_columns(state: "withdrawn") # rubocop:disable Rails/SkipsModelValidations

    expect { 2.times { described_class.perform_now } }.not_to change(AuditEvent, :count)
    expect(old.reload.state).to eq("withdrawn")
  end
end
