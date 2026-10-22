# typed: true
# frozen_string_literal: true

require "prometheus/client/formats/text"

# GET /metrics — Prometheus text exposition of the Metrics registry.
# Unlike /healthz (which only says "up"), it requires a bearer token when
# METRICS_TOKEN is set, and always in production (see MetricsAuth).
class MetricsController < ApplicationController
  extend T::Sig

  before_action :require_scrape_token

  sig { void }
  def show
    # Gauges are set by the sweepers; refresh the cheap ones on scrape so a
    # fresh process reports the truth before its first sweep.
    Metrics.gauge(:unknown_state_payments, Payment.where(state: "unknown").count)
    Metrics.gauge(:outbound_events_pending, OutboundEvent.where(state: "pending").count)
    Metrics.gauge(:outbound_events_dead, OutboundEvent.where(state: "dead").count)

    render plain: Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY),
           content_type: Prometheus::Client::Formats::Text::CONTENT_TYPE
  end

  private

  sig { void }
  def require_scrape_token
    return if MetricsAuth.authorized?(request.authorization)

    response.headers["WWW-Authenticate"] = 'Bearer realm="metrics"'
    head :unauthorized
  end
end
