# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-06/O-07: maker-checker proposals. create/list/withdraw here;
    # approve/reject in the decide flow.
    class ProposalsController < BaseController
      extend T::Sig

      requires_permission "ops.payments.read", only: :index
      requires_permission "ops.proposals.create", only: %i[create withdraw]
      requires_permission "ops.proposals.decide", only: %i[approve reject]

      sig { void }
      def index
        scope = OperatorProposal.includes(:payment, :proposed_by, :decided_by).order(created_at: :desc).limit(100)
        scope = scope.where(state: params[:state]) if params[:state].present?
        render json: { "data" => scope.map { |p| ProposalSerializer.call(p, viewer: current_user) } }
      end

      # client_token makes a double-submit safe: the proposer gets their
      # proposal back. Another operator's token is never theirs to see.
      sig { void }
      def create
        token = params.require(:client_token).to_s
        existing = OperatorProposal.find_by(client_token: token)
        return render_existing_proposal(existing) if existing

        proposal = begin
          OperatorProposal.create!(
            kind: params.require(:kind), payment: Payment.find(params.require(:payment_id)),
            payload: payload_params, reason_code: params.require(:reason_code),
            reason_text: params.require(:reason_text), case_reference: params.require(:case_reference),
            client_token: token, proposed_by: current_user
          )
        rescue ActiveRecord::RecordNotUnique
          # The same token committed between our lookup and insert (two submits at once).
          return render_existing_proposal(OperatorProposal.where(client_token: token).take!)
        end
        audit!("proposal.created", target: proposal, merchant_id: T.must(proposal.payment).merchant_id,
                                   metadata: proposal.slice(:kind, :payload, :reason_code, :case_reference))
        notify_approvers(proposal)
        render json: ProposalSerializer.call(proposal, viewer: current_user), status: :created
      end

      # TC-N6-4: re-read under the row lock DecideProposal and
      # ExpireProposalsJob take, so an approval or expiry that commits first
      # makes this a 409 instead of being overwritten to withdrawn.
      sig { void }
      def withdraw
        proposal = OperatorProposal.transaction do
          locked = OperatorProposal.lock.find(params[:id])
          unless locked.proposed_by_id == current_user.id && locked.state == "pending"
            raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused",
                               message: "Only the proposer can withdraw a pending proposal")
          end

          locked.update!(state: "withdrawn")
          locked
        end
        audit!("proposal.withdrawn", target: proposal, merchant_id: T.must(proposal.payment).merchant_id)
        render json: ProposalSerializer.call(proposal, viewer: current_user)
      end

      sig { void }
      def approve = decide(approve: true)

      sig { void }
      def reject = decide(approve: false)

      private

      sig { params(existing: OperatorProposal).void }
      def render_existing_proposal(existing)
        unless existing.proposed_by_id == current_user.id
          raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "client_token_in_use",
                             param: "client_token", message: "This client_token belongs to another proposal")
        end

        render json: ProposalSerializer.call(existing, viewer: current_user)
      end

      sig { params(approve: T::Boolean).void }
      def decide(approve:)
        note = params[:note].to_s.strip.presence
        raise ApiError.validation("note" => ["is required to reject"]) if !approve && note.nil?

        proposal = DecideProposal.call(params[:id], approver: current_user, approve:, note:)
        audit!("proposal.#{proposal.state}", target: proposal, merchant_id: T.must(proposal.payment).merchant_id,
                                             metadata: { "note" => note, "error" => proposal.error }.compact)
        render json: ProposalSerializer.call(proposal.reload, viewer: current_user)
      end

      # Only the keys either payload shape uses; the model validates the shape.
      sig { returns(T::Hash[String, T.untyped]) }
      def payload_params
        params.require(:payload).permit(:to_state, :currency, legs: %i[account_kind direction amount_minor]).to_h
      end

      # A mailing list, not an authorization check: select by permission.
      sig { params(proposal: OperatorProposal).void }
      def notify_approvers(proposal)
        Operator.active.each do |operator|
          next unless Permissions.granted?(:operator, operator.role, "ops.proposals.decide")

          OperatorMailer.proposal_waiting(proposal, operator).deliver_later
        end
      end
    end
  end
end
