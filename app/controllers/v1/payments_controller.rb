# typed: true
# frozen_string_literal: true

module V1
  class PaymentsController < BaseController
    extend T::Sig

    # GET /v1/payments — cursor pagination, filters on state, currency, created_at range.
    # Must stay under 100ms at 1M rows: keyset predicate on the (merchant_id, created_at, id) index,
    # no COUNT, no OFFSET, no N+1 (transitions are not loaded for the list).
    sig { void }
    def index
      scope = current_merchant.payments
      scope = scope.where(state: params[:state]) if params[:state].present?
      scope = scope.where(currency: params[:currency]) if params[:currency].present?
      scope = scope.where(created_at: Time.iso8601(params[:created_after])..) if params[:created_after].present?
      scope = scope.where(created_at: ..Time.iso8601(params[:created_before])) if params[:created_before].present?

      page = Cursor.paginate(scope, after: params[:cursor].presence, limit: params[:limit]&.to_i)
      render json: {
        "object" => "list",
        "data" => page.records.map { |p| PaymentSerializer.call(p) },
        "has_more" => page.has_more,
        "next_cursor" => page.next_cursor
      }
    rescue Cursor::Invalid => e
      raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
    rescue ArgumentError => e
      raise ApiError.invalid_request("created_after/created_before must be ISO-8601: #{e.message}", param: "created_after")
    end

    # POST /v1/payments → 202 pending. Never blocks on the PSP.
    sig { void }
    def create
      payment = CreatePayment.call(current_merchant, validated_params)
      @log_payment_id = payment.id # created mid-action; put it on this request's log line
      @log_psp_name = payment.psp_name
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
