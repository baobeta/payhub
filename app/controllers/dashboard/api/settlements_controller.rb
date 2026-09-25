# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-09: what the PSP paid out and kept in fees, per day and currency.
    class SettlementsController < BaseController
      requires_permission "settlements.read", only: :index

      def index
        rows = SettlementLine.joins("JOIN payments ON payments.id = settlement_lines.payment_id")
                             .where(payments: { merchant_id: current_merchant.id })
                             .group(:settled_on, "settlement_lines.currency")
                             .order(settled_on: :desc).limit(90)
                             .pluck(:settled_on, "settlement_lines.currency", Arel.sql("SUM(gross_minor)"),
                                    Arel.sql("SUM(fee_minor)"), Arel.sql("SUM(net_minor)"))
        render json: {
          "data" => rows.map do |day, currency, gross, fee, net|
            { "settled_on" => day.iso8601, "currency" => currency, "gross_minor" => gross.to_i, "fee_minor" => fee.to_i,
              "net_minor" => net.to_i } # SUM(bigint) is numeric in Postgres
          end
        }
      end
    end
  end
end
