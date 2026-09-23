# typed: false
# frozen_string_literal: true

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/all"

otlp_endpoint_configured = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].present? ||
                           ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"].present?
ENV["OTEL_TRACES_EXPORTER"] ||= otlp_endpoint_configured ? "otlp" : "none"

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "payhub")
  # Jobs continue the enqueuing request's trace (the default :link starts a new
  # root per job), so request -> enqueue -> job -> PSP call reads as one trace.
  c.use_all(
    "OpenTelemetry::Instrumentation::ActiveJob" => { propagation_style: :child },
    "OpenTelemetry::Instrumentation::Sidekiq" => { propagation_style: :child }
  )
end
