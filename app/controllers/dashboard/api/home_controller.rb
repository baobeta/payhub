# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-01: attention first, then volume and balance.
    class HomeController < BaseController
      requires_permission "payments.read", only: :show

      def show
        payments = current_merchant.payments
        render json: {
          "needs_attention" => payments.where(state: %w[requires_action unknown]).group(:state).count,
          "volume_7d" => payments.where(created_at: 7.days.ago..).where.not(state: %w[failed canceled])
                                 .group(:currency).sum(:amount_minor),
          "balance" => permission_granted?("balance.read") ? Ledger.balances(current_merchant) : nil
        }
      end
    end
  end
end
