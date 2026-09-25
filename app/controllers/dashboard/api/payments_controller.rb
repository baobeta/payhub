# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class PaymentsController < BaseController
      EXPORT_LIMIT = 10_000
      CSV_COLUMNS = %w[id created_at state amount_minor currency captured_minor psp_name psp_reference].freeze

      requires_permission "payments.read", only: %i[index show]
      requires_permission "payments.export", only: :export
      requires_permission "payments.capture", only: :capture
      requires_permission "payments.cancel", only: :cancel
      idempotent only: %i[capture cancel] # after requires_permission: denials never claim a key

      def index
        page = Cursor.paginate(filtered, after: params[:cursor].presence, limit: params[:limit]&.to_i)
        render json: { "object" => "list", "data" => page.records.map { |p| PaymentSerializer.call(p) },
                       "has_more" => page.has_more, "next_cursor" => page.next_cursor }
      rescue Cursor::Invalid => e
        raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
      end

      def export
        rows = filtered.order(created_at: :desc, id: :desc).limit(EXPORT_LIMIT + 1).to_a
        response.set_header("X-Export-Truncated", "true") if rows.size > EXPORT_LIMIT
        csv = CSV.generate do |out|
          out << CSV_COLUMNS
          rows.first(EXPORT_LIMIT).each do |p|
            out << CsvSafe.row([p.id, p.created_at.utc.iso8601, p.state, p.amount_minor, p.currency, p.captured_minor,
                                p.psp_name, p.psp_reference])
          end
        end
        send_data csv, type: "text/csv", filename: "payments-#{Time.current.utc.to_date}.csv"
      end

      def show
        @skip_request_log = request.headers["X-Poll"] == "1"
        render json: detail(current_merchant.payments.find(params[:id]))
      end

      def capture
        payment = current_merchant.payments.find(params[:id])
        CapturePayment.call(payment, amount_minor: optional_amount)
        audit!("payment.capture_requested", target: payment)
        render json: detail(payment.reload), status: :accepted
      end

      def cancel
        payment = current_merchant.payments.find(params[:id])
        CancelPayment.call(payment, source: "api", reason: params[:reason].presence&.to_s)
        audit!("payment.canceled", target: payment)
        render json: detail(payment.reload)
      end

      private

      def filtered
        PaymentFilters.apply(current_merchant.payments, params)
      rescue ArgumentError => e
        raise ApiError.invalid_request("created_after/created_before must be ISO-8601: #{e.message}", param: "created_after")
      end

      def detail(payment)
        PaymentSerializer.call(payment).merge(
          "timeline" => PaymentTimeline.call(payment),
          "can" => PaymentActions.call(payment, granted: ->(p) { permission_granted?(p) })
        )
      end

      def optional_amount
        raw = params[:amount_minor]
        return nil if raw.nil?
        return raw if raw.is_a?(Integer) && raw.positive?

        raise ApiError.validation("amount_minor" => ["must be a positive integer when present"])
      end
    end
  end
end
