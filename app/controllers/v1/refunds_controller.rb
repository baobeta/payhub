# typed: true
# frozen_string_literal: true

module V1
  class RefundsController < BaseController
    extend T::Sig

    # POST /v1/payments/:payment_id/refunds → 202 pending refund.
    # Partial and repeated refunds allowed up to the captured amount.
    sig { void }
    def create
      payment = current_merchant.payments.find(params[:payment_id])
      raw = params[:amount_minor]
      amount = if raw.nil? then nil
      elsif raw.is_a?(Integer) && raw.positive? then raw
      else raise ApiError.validation("amount_minor" => ["must be a positive integer when present"])
      end

      @log_payment_id = payment.id
      @log_psp_name = payment.psp_name
      refund = CreateRefund.call(payment, amount_minor: amount, reason: params[:reason].presence&.to_s)
      render json: RefundSerializer.call(refund), status: :accepted
    end
  end
end
