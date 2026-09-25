# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-22: the merchant's slice of the append-only audit log, 12 months.
    class SecurityHistoryController < BaseController
      EXPORT_LIMIT = 10_000

      requires_permission "security_history.read", only: %i[index export]

      def index
        page = Cursor.paginate(scope, after: params[:cursor].presence, limit: params[:limit]&.to_i)
        render json: { "object" => "list", "data" => page.records.map { |e| row(e) },
                       "has_more" => page.has_more, "next_cursor" => page.next_cursor }
      rescue Cursor::Invalid => e
        raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
      end

      def export
        csv = CSV.generate do |out|
          out << %w[at actor action result target ip livemode]
          scope.order(created_at: :desc).limit(EXPORT_LIMIT).each do |e|
            out << CsvSafe.row([e.created_at.utc.iso8601, e.actor_label, e.action, e.result, e.target_type, e.ip, e.metadata["livemode"]])
          end
        end
        send_data csv, type: "text/csv", filename: "security-history-#{Time.current.utc.to_date}.csv"
      end

      private

      def scope = AuditEvent.where(merchant_id: live_merchant.id)

      def row(event)
        { "id" => event.id, "at" => event.created_at.utc.iso8601, "actor" => event.actor_label, "action" => event.action,
          "result" => event.result, "target_type" => event.target_type, "ip" => event.ip, "metadata" => event.metadata }
      end
    end
  end
end
