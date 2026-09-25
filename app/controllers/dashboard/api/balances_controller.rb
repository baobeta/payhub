# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-08: available (merchant_payable) and reserved for refunds, per currency.
    class BalancesController < BaseController
      requires_permission "balance.read", only: :show

      def show
        available = Ledger.balances(current_merchant)
        reserved = Ledger.reserved_balances(current_merchant)
        currencies = (available.keys | reserved.keys).sort
        render json: {
          "data" => currencies.map do |c|
            { "currency" => c, "available_minor" => available.fetch(c, 0), "reserved_minor" => reserved.fetch(c, 0) }
          end
        }
      end
    end
  end
end
