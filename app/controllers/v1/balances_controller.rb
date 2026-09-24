# typed: true
# frozen_string_literal: true

module V1
  class BalancesController < BaseController
    extend T::Sig

    # GET /v1/balance → what we owe the merchant, per currency, derived from
    # the ledger. `pending` is refunds reserved but not yet confirmed by the
    # PSP: already out of `available`, not yet back with the customer (#16).
    sig { void }
    def show
      render json: {
        "object" => "balance",
        "available" => amounts(Ledger.balances(current_merchant)),
        "pending" => amounts(Ledger.reserved_balances(current_merchant))
      }
    end

    private

    sig { params(balances: T::Hash[String, Integer]).returns(T::Array[T::Hash[String, T.untyped]]) }
    def amounts(balances)
      balances.map do |currency, minor|
        { "currency" => currency, "amount_minor" => minor, "display_amount" => Currency.to_display(minor, currency) }
      end
    end
  end
end
