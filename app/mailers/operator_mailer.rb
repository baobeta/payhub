# frozen_string_literal: true

class OperatorMailer < ApplicationMailer
  def invite(operator, token)
    @url = app_url("/ops/invitations/#{token}")
    @role = operator.role
    mail(to: operator.email, subject: "Your PayHub operator account")
  end

  def proposal_waiting(proposal, approver)
    @proposal = proposal
    @url = app_url("/ops/proposals")
    mail(to: approver.email, subject: "Proposal waiting: #{proposal.case_reference}")
  end
end
