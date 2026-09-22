# typed: true

class HealthController < ApplicationController
  # Liveness: proves the process is up and can reach the database.
  # Deeper checks (Redis, Sidekiq queue depth) belong on /metrics, not here —
  # a liveness probe that fails on a slow dependency causes restarts, not fixes.
  def show
    ActiveRecord::Base.connection.execute("SELECT 1")
    render json: { status: "ok" }
  rescue ActiveRecord::ActiveRecordError, PG::Error => e
    render json: { status: "degraded", error: e.class.name }, status: :service_unavailable
  end
end
