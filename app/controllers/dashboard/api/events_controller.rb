# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-16, M-17: the delivery log. Same serializer as /v1/events.
    class EventsController < BaseController
      requires_permission "webhooks.read", only: %i[index show]
      requires_permission "events.redeliver", only: :redeliver

      def index
        scope = current_merchant.outbound_events
        scope = scope.where(state: params[:state]) if params[:state].present?
        scope = scope.where(payment_id: params[:payment_id]) if params[:payment_id].present?
        page = Cursor.paginate(scope, after: params[:cursor].presence, limit: params[:limit]&.to_i)
        render json: { "object" => "list", "data" => page.records.map { |e| EventSerializer.call(e, include_attempts: false) },
                       "has_more" => page.has_more, "next_cursor" => page.next_cursor }
      rescue Cursor::Invalid => e
        raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
      end

      def show = render(json: EventSerializer.call(current_merchant.outbound_events.find(params[:id])))

      def redeliver
        event = current_merchant.outbound_events.find(params[:id])
        unless event.dead?
          raise ApiError.invalid_request("Only dead events can be redelivered (state: #{event.state})",
                                         code: "invalid_state", param: "id")
        end

        event.redeliver!
        DeliverOutboundEventsJob.perform_later
        audit!("event.redelivered", target: event)
        render json: EventSerializer.call(event.reload), status: :accepted
      end
    end
  end
end
