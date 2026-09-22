# typed: true
# frozen_string_literal: true

module V1
  class EventsController < BaseController
    extend T::Sig

    # GET /v1/events — outbound events and their delivery attempts, newest first.
    # Filters: state, type, payment_id. Cursor pagination.
    sig { void }
    def index
      scope = current_merchant.outbound_events.includes(:delivery_attempts)
      scope = scope.where(state: params[:state]) if params[:state].present?
      scope = scope.where(event_type: params[:type]) if params[:type].present?
      scope = scope.where(payment_id: params[:payment_id]) if params[:payment_id].present?

      page = Cursor.paginate(scope, after: params[:cursor].presence, limit: params[:limit]&.to_i)
      render json: {
        "object" => "list",
        "data" => page.records.map { |e| EventSerializer.call(e) },
        "has_more" => page.has_more,
        "next_cursor" => page.next_cursor
      }
    rescue Cursor::Invalid => e
      raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
    end

    # POST /v1/events/:id/redeliver — operator replay from the dead-letter state.
    sig { void }
    def redeliver
      event = current_merchant.outbound_events.find(params[:id])
      unless event.dead?
        raise ApiError.invalid_request("Only dead events can be redelivered (state: #{event.state})",
                                       code: "invalid_state", param: "id")
      end

      event.redeliver!
      DeliverOutboundEventsJob.perform_later
      render json: EventSerializer.call(event.reload), status: :accepted
    end
  end
end
