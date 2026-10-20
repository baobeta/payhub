# typed: true
# frozen_string_literal: true

module Demo
  module Api
    # D-04: the demo's chaos button. One run at a time, system-wide; the
    # simulator being hostile for its duration means a second run would not be
    # a "normal" run anyway.
    class ChaosRunsController < BaseController
      extend T::Sig

      MAX_PAYMENTS = 20

      sig { void }
      def create
        requested = params[:payments].to_i.clamp(1, MAX_PAYMENTS)
        run = DemoChaosRun.create!(payments: requested, started_by_ip: request.remote_ip)
        DemoChaosRunJob.perform_later(run.id)
        render json: { "id" => run.id, "state" => run.state, "payments" => run.payments }, status: :accepted
      rescue ActiveRecord::RecordNotUnique
        active = T.must(DemoChaosRun.active.first)
        raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "chaos_run_in_progress",
                           message: "A chaos run is already running",
                           details: { "active_run_id" => [active.id] })
      end

      sig { void }
      def show
        run = DemoChaosRun.find(params[:id])
        render json: {
          "id" => run.id, "state" => run.state, "payments" => run.payments,
          "result" => run.result, "error" => run.error,
          "finished_at" => run.finished_at&.utc&.iso8601(3)
        }
      end
    end
  end
end
