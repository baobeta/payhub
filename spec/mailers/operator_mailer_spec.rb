# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorMailer do
  describe "#invite" do
    let(:operator) { create(:operator, email: "new.op@example.com", role: "approver") }
    let(:mail) { described_class.invite(operator, "tok_abc") }

    it "TC-COV-OM-1 goes to the invited operator" do
      expect(mail.to).to eq(["new.op@example.com"])
      expect(mail.subject).to eq("Your PayHub operator account")
    end

    it "TC-COV-OM-2 carries the role and the acceptance link with the token" do
      expect(mail.body.encoded).to include("as approver", "/ops/invitations/tok_abc")
    end
  end

  describe "#proposal_waiting" do
    let(:approver) { create(:operator, email: "checker@example.com", role: "approver") }
    let(:proposal) { create(:operator_proposal, payment: create(:payment, state: "unknown"), case_reference: "OPS-77", reason_text: "PSP confirmed the outcome") }
    let(:mail) { described_class.proposal_waiting(proposal, approver) }

    it "TC-COV-OM-3 goes to the approver, naming the case" do
      expect(mail.to).to eq(["checker@example.com"])
      expect(mail.subject).to eq("Proposal waiting: OPS-77")
    end

    it "TC-COV-OM-4 says what is proposed and links to the proposals queue" do
      expect(mail.body.encoded).to include("Case: OPS-77", "Kind: payment_transition",
                                           "Reason: PSP confirmed the outcome", "/ops/proposals")
    end

    it "TC-COV-OM-5 carries no payment card data" do
      expect(mail.body.encoded).not_to include(proposal.payment.payment_method_token)
    end
  end
end
