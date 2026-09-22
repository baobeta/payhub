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

    # POST /v1/payments/:id/capture → 202. Partial allowed; defaults to the full authorized amount.
    sig { void }
    def capture
      payment = current_merchant.payments.find(params[:id])
      amount = optional_amount
      CapturePayment.call(payment, amount_minor: amount)
      render json: PaymentSerializer.call(payment.reload), status: :accepted
    end

    # POST /v1/payments/:id/cancel → 200. Synchronous; only valid from authorized.
    sig { void }
    def cancel
      payment = current_merchant.payments.find(params[:id])
      CancelPayment.call(payment)
      render json: PaymentSerializer.call(payment.reload, include_transitions: true)
    end

    private

    # amount_minor for capture/refund: absent means "all of it"; present must be a positive integer.
    sig { returns(T.nilable(Integer)) }
    def optional_amount
      raw = params[:amount_minor]
      return nil if raw.nil?
      return raw if raw.is_a?(Integer) && raw.positive?

      raise ApiError.validation("amount_minor" => ["must be a positive integer when present"])
    end

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
