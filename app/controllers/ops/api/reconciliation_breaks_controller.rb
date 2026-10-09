# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-11: reconciliation and settlement breaks. Settlement lines can be
    # marked reviewed; ledger breaks are read-only (fixing them is a proposal).
    class ReconciliationBreaksController < BaseController
      requires_permission "ops.reconciliation.read", only: :index
      requires_permission "ops.reconciliation.review", only: :review

      def index
        render json: {
          "settlement_lines" => settlement_lines,
          "ledger" => {
            "unbalanced_transfer_ids" => Ledger.unbalanced_transfer_ids,
            "reservation_drift_refund_ids" => Ledger.reservation_drift_refund_ids
          }
        }
      end

      def review
        line = SettlementLine.find(params[:id])
        if line.reviewed_at.present?
          raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "already_reviewed",
                             message: "This break was already reviewed")
        end

        line.update!(reviewed_at: Time.current, reviewed_by_id: current_user.id, review_note: reason!)
        audit!("reconciliation.reviewed", target: line, merchant_id: line.payment&.merchant_id,
                                          metadata: { "reason" => line.review_note })
        render json: { "id" => line.id, "reviewed_at" => T.must(line.reviewed_at).utc.iso8601 }
      end

      private

      def settlement_lines
        SettlementLine.where(status: %w[unmatched mismatch]).order(booked_at: :desc).limit(200).map do |l|
          { "id" => l.id, "psp_name" => l.psp_name, "external_id" => l.external_id, "kind" => l.kind,
            "status" => l.status, "problem" => l.problem, "payment_id" => l.payment_id,
            "psp_reference" => l.psp_reference, "gross_minor" => l.gross_minor, "fee_minor" => l.fee_minor,
            "net_minor" => l.net_minor, "currency" => l.currency, "settled_on" => l.settled_on.iso8601,
            "reviewed_at" => l.reviewed_at&.utc&.iso8601, "reviewed_by_id" => l.reviewed_by_id,
            "review_note" => l.review_note }
        end
      end
    end
  end
end
