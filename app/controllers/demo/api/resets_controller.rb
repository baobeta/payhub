# typed: true
# frozen_string_literal: true

module Demo
  module Api
    # D-06: reset the demo. Not a delete — payments and ledger entries are
    # append-only (DECISIONS #27). It starts a new epoch, and the demo shows
    # only what came after it.
    class ResetsController < BaseController
      COOLDOWN = 1.minute

      def create
        latest = DemoEpoch.order(:started_at).last
        if latest && Time.current - latest.started_at < COOLDOWN
          raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 429, code: "reset_too_soon",
                             message: "The demo was just reset; please wait a moment",
                             retriable: true)
        end
        raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "chaos_run_in_progress",
                           message: "A chaos run is running; reset after it finishes") if DemoChaosRun.active.exists?

        epoch = DemoEpoch.create!(started_at: Time.current, started_by_ip: request.remote_ip)
        render json: { "id" => epoch.id, "started_at" => epoch.started_at.utc.iso8601(3) }, status: :created
      end
    end
  end
end
