# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-05: a dead webhook can be sent again, but never silently.
    class EventsController < BaseController
      requires_permission "ops.events.redeliver", only: :redeliver

      def redeliver
        reason = reason!
        event = OutboundEvent.find(params[:id])
        unless event.dead?
          raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 422, code: "invalid_state",
                             message: "Only dead events can be redelivered (state: #{event.state})")
        end

        event.redeliver!
        DeliverOutboundEventsJob.perform_later
        audit!("event.redelivered", target: event, merchant_id: event.merchant_id, metadata: { "reason" => reason })
        render json: { "id" => event.id, "state" => event.reload.state }
      end
    end
  end
end
