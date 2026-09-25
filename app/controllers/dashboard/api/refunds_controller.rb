# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-07: same service as /v1, but the UI requires a reason (use cases).
    class RefundsController < BaseController
      REASONS = %w[requested_by_customer duplicate fraudulent other].freeze

      requires_permission "payments.refund", only: :create
      idempotent only: :create

      def create
        payment = current_merchant.payments.find(params[:payment_id])
        reason = params[:reason].to_s
        raise ApiError.validation("reason" => ["must be one of #{REASONS.join(', ')}"]) unless REASONS.include?(reason)

        amount = params[:amount_minor]
        unless amount.nil? || (amount.is_a?(Integer) && amount.positive?)
          raise ApiError.validation("amount_minor" => ["must be a positive integer"])
        end

        refund = CreateRefund.call(payment, amount_minor: amount, reason:)
        audit!("payment.refund_requested", target: payment,
                                           metadata: { "refund_id" => refund.id, "amount_minor" => refund.amount_minor })
        render json: RefundSerializer.call(refund), status: :accepted
      end
    end
  end
end
