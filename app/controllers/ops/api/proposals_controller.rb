# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-06/O-07: maker-checker proposals. create/list/withdraw here;
    # approve/reject in the decide flow.
    class ProposalsController < BaseController
      requires_permission "ops.payments.read", only: :index
      requires_permission "ops.proposals.create", only: %i[create withdraw]
      requires_permission "ops.proposals.decide", only: %i[approve reject]

      def index
        scope = OperatorProposal.includes(:payment, :proposed_by, :decided_by).order(created_at: :desc).limit(100)
        scope = scope.where(state: params[:state]) if params[:state].present?
        render json: { "data" => scope.map { |p| ProposalSerializer.call(p, viewer: current_user) } }
      end

      def create
        existing = OperatorProposal.find_by(client_token: params.require(:client_token))
        if existing&.proposed_by_id == current_user.id
          return render(json: ProposalSerializer.call(existing, viewer: current_user))
        end

        proposal = OperatorProposal.create!(
          kind: params.require(:kind), payment: Payment.find(params.require(:payment_id)),
          payload: payload_params, reason_code: params.require(:reason_code),
          reason_text: params.require(:reason_text), case_reference: params.require(:case_reference),
          client_token: params[:client_token], proposed_by: current_user
        )
        audit!("proposal.created", target: proposal, merchant_id: T.must(proposal.payment).merchant_id,
                                   metadata: proposal.slice(:kind, :payload, :reason_code, :case_reference))
        notify_approvers(proposal)
        render json: ProposalSerializer.call(proposal, viewer: current_user), status: :created
      end

      def withdraw
        proposal = OperatorProposal.find(params[:id])
        unless proposal.proposed_by_id == current_user.id && proposal.state == "pending"
          raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused",
                             message: "Only the proposer can withdraw a pending proposal")
        end

        proposal.update!(state: "withdrawn")
        audit!("proposal.withdrawn", target: proposal, merchant_id: T.must(proposal.payment).merchant_id)
        render json: ProposalSerializer.call(proposal, viewer: current_user)
      end

      def approve = decide(approve: true)
      def reject = decide(approve: false)

      private

      def decide(approve:)
        note = params[:note].to_s.strip.presence
        raise ApiError.validation("note" => ["is required to reject"]) if !approve && note.nil?

        proposal = DecideProposal.call(params[:id], approver: current_user, approve:, note:)
        audit!("proposal.#{proposal.state}", target: proposal, merchant_id: T.must(proposal.payment).merchant_id,
                                             metadata: { "note" => note, "error" => proposal.error }.compact)
        render json: ProposalSerializer.call(proposal.reload, viewer: current_user)
      end

      # Only the keys either payload shape uses; the model validates the shape.
      def payload_params
        params.require(:payload).permit(:to_state, :currency, legs: %i[account_kind direction amount_minor]).to_h
      end

      # A mailing list, not an authorization check: select by permission.
      def notify_approvers(proposal)
        Operator.active.each do |operator|
          next unless Permissions.granted?(:operator, operator.role, "ops.proposals.decide")

          OperatorMailer.proposal_waiting(proposal, operator).deliver_later
        end
      end
    end
  end
end
