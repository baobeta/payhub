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
  c.use_all
end
