# typed: true
# frozen_string_literal: true

require "prometheus/client/formats/text"

# GET /metrics — Prometheus text exposition of the Metrics registry.
# Unauthenticated like /healthz: scraped from inside the network. In a real
# deployment both sit behind the load balancer's internal listener.
class MetricsController < ApplicationController
  def show
    # Gauges are set by the sweepers; refresh the cheap ones on scrape so a
    # fresh process reports the truth before its first sweep.
    Metrics.gauge(:unknown_state_payments, Payment.where(state: "unknown").count)
    Metrics.gauge(:outbound_events_pending, OutboundEvent.where(state: "pending").count)
    Metrics.gauge(:outbound_events_dead, OutboundEvent.where(state: "dead").count)

    render plain: Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY),
           content_type: Prometheus::Client::Formats::Text::CONTENT_TYPE
  end
end
