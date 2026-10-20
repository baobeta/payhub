# typed: true
# frozen_string_literal: true

module Demo
  module Api
    # D-05: the ledger is the truth, and it is readable here without a login.
    # Only the demo twin's, only since the current epoch.
    class LedgerController < BaseController
      LIMIT = 50

      def show
        entries = LedgerEntry.joins(:account)
                             .where(ledger_accounts: { merchant_id: merchant.id })
                             .where(created_at: DemoMerchant.epoch_started_at..)
                             .order(created_at: :desc)

        grouped = entries.group_by(&:transfer_id).to_a.first(LIMIT)
        transfers = grouped.map do |transfer_id, legs|
          nets = legs.group_by(&:currency).transform_values do |by_currency|
            by_currency.sum { |l| l.direction == "debit" ? -l.amount_minor : l.amount_minor }
          end
          {
            "transfer_id" => transfer_id,
            "at" => T.must(legs.map(&:created_at).min).utc.iso8601(3),
            "currency" => T.must(legs.first).currency,
            "legs" => legs.map do |l|
              { "account" => T.must(l.account).kind, "direction" => l.direction, "amount_minor" => l.amount_minor }
            end,
            "nets_to_zero" => nets.values.all?(&:zero?),
            "per_currency" => nets
          }
        end

        shown_ids = transfers.pluck("transfer_id")
        render json: {
          "transfers" => transfers,
          "all_balanced" => (Ledger.unbalanced_transfer_ids & shown_ids).empty?
        }
      end
    end
  end
end
