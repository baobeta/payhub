# typed: false
# frozen_string_literal: true

require "opentelemetry-api"

module Tracing
  module_function

  def tracer
    OpenTelemetry.tracer_provider.tracer("payhub")
  end

  def in_span(name, attributes: {})
    tracer.in_span(name, attributes: attributes.compact) do |span|
      yield span
    rescue StandardError => error
      span.record_exception(error) if span.respond_to?(:record_exception)
      span.status = OpenTelemetry::Trace::Status.error(error.message) if span.respond_to?(:status=)
      raise
    end
  end

  def ids
    context = OpenTelemetry::Trace.current_span.context
    return {} unless context.valid?

    {
      trace_id: context.hex_trace_id,
      span_id: context.hex_span_id
    }
  rescue StandardError
    {}
  end
end
