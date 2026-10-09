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

      private

      def detail(payment)
        PaymentSerializer.call(payment).merge("timeline" => PaymentTimeline.call(payment))
      end
    end
  end
end
