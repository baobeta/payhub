# typed: true
# frozen_string_literal: true

module Demo
  module Api
    # Every demo payment is created from a scenario, which fixes the payment
    # method token (and therefore the outcome) on the server. A visitor never
    # chooses the token (use cases D-01..D-06).
    class PaymentsController < BaseController
      SCENARIOS = {
        "success" => { token: "tok_demo_success", currency: "EUR", amount_minor: 2500 },
        "decline" => { token: "tok_demo_decline", currency: "EUR", amount_minor: 2500 },
        "timeout_then_webhook" => { token: "tok_demo_timeout_webhook", currency: "EUR", amount_minor: 2500 },
        "timeout_needs_operator" => { token: "tok_demo_timeout_needs_operator", currency: "EUR", amount_minor: 2500 },
        "wallet_redirect" => { token: "tok_demo_wallet", currency: "VND", amount_minor: 500_000 }
      }.freeze

      def create
        scenario = params.require(:scenario).to_s
        choice = SCENARIOS.fetch(scenario) do
          raise ApiError.validation("scenario" => ["must be one of #{SCENARIOS.keys.join(', ')}"])
        end

        payment = CreatePayment.call(merchant, CreatePayment::Params.new(
          amount_minor: choice[:amount_minor], currency: choice[:currency], payment_method_token: choice[:token],
          capture: params[:capture] == true, metadata: { "demo_scenario" => scenario }
        ))
        render json: detail(payment), status: :accepted
      end

      def show = render(json: detail(DemoMerchant.payments.find(params[:id])))

      # D-03: the visitor pressing "approve" in their wallet app. A wallet
      # charges only after redirect approval, and only the simulator can say
      # yes, so this exists for the same reason the simulator does.
      def approve_wallet
        raise ApiError.not_found("resource") if Rails.env.production?

        payment = DemoMerchant.payments.find(params[:id])
        unless payment.state == "requires_action" && payment.psp_name == "kiripay"
          raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "not_approvable",
                             message: "Only a wallet redirect waiting for approval can be approved")
        end

        charge_id = payment.transitions.reload.order(:created_at).last&.metadata&.dig("psp_charge_id")
        if charge_id.blank?
          raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "not_approvable",
                             message: "No wallet charge to approve")
        end

        response = kiripay_conn.post("_sim/charges/#{charge_id}/approve")
        unless response.status.between?(200, 299)
          raise ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 503, code: "psp_unavailable",
                             message: "the wallet did not respond", retriable: true)
        end

        render(json: detail(payment.reload))
      end

      private

      # A plain connection to the simulator: not the PSP adapter, because this
      # is not a PSP call — it is the customer's own approval.
      def kiripay_conn
        @kiripay_conn ||= Faraday.new(url: ENV.fetch("KIRIPAY_URL", "http://localhost:4002")) do |f|
          f.request :json
          f.response :json, content_type: /\bjson$/
          f.options.open_timeout = 1
          f.options.timeout = 3
          f.adapter Faraday.default_adapter
        end
      end

      def detail(payment)
        PaymentSerializer.call(payment).merge("timeline" => PaymentTimeline.call(payment))
      end
    end
  end
end
