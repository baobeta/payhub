# typed: true
# frozen_string_literal: true

class OperatorMailer < ApplicationMailer
  sig { params(operator: Operator, token: String).void }
  def invite(operator, token)
    @url = app_url("/ops/invitations/#{token}")
    @role = operator.role
    mail(to: operator.email, subject: "Your PayHub operator account")
  end

  sig { params(proposal: OperatorProposal, approver: Operator).void }
  def proposal_waiting(proposal, approver)
    @proposal = proposal
    @url = app_url("/ops/proposals")
    mail(to: approver.email, subject: "Proposal waiting: #{proposal.case_reference}")
  end
end
