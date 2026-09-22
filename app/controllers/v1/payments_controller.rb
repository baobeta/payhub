# typed: true
# frozen_string_literal: true

module V1
  class PaymentsController < BaseController
    extend T::Sig

    # POST /v1/payments → 202 pending. Never blocks on the PSP.
    sig { void }
    def create
      payment = CreatePayment.call(current_merchant, validated_params)
      render json: PaymentSerializer.call(payment), status: :accepted
    end

    # GET /v1/payments/:id → current state plus full transition history.
    sig { void }
    def show
      payment = current_merchant.payments.includes(:transitions).find(params[:id])
      render json: PaymentSerializer.call(payment, include_transitions: true)
    end

    private

    # Collects EVERY failing field before raising, as the contract requires.
    sig { returns(CreatePayment::Params) }
    def validated_params
      errors = Hash.new { |h, k| h[k] = [] }
      body = params.permit(:amount_minor, :currency, :payment_method_token, :capture, metadata: {}).to_h

      amount = body["amount_minor"]
      errors["amount_minor"] << "must be a positive integer" unless amount.is_a?(Integer) && amount.positive?

      currency = body["currency"].to_s
      if currency.empty?
        errors["currency"] << "is required"
      elsif !Currency.supported?(currency)
        errors["currency"] << "is not supported (#{Currency::SUPPORTED.join(', ')})"
      end

      errors["payment_method_token"] << "is required" if body["payment_method_token"].to_s.empty?

      capture = body.fetch("capture", false)
      errors["capture"] << "must be true or false" unless [true, false].include?(capture)

      raise ApiError.validation(errors) if errors.any?

      CreatePayment::Params.new(
        amount_minor: amount, currency: currency, payment_method_token: body["payment_method_token"],
        capture: capture, metadata: body.fetch("metadata", {})
      )
    end
  end
end
