# typed: true
# frozen_string_literal: true

module V1
  class BalancesController < BaseController
    extend T::Sig

    # GET /v1/balance → what we owe the merchant, per currency, derived from the ledger.
    sig { void }
    def show
      balances = Ledger.balances(current_merchant)
      render json: {
        "object" => "balance",
        "available" => balances.map do |currency, minor|
          { "currency" => currency, "amount_minor" => minor, "display_amount" => Currency.to_display(minor, currency) }
        end
      }
    end
  end
end
