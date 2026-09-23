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

  def inject_context
    carrier = {}
    OpenTelemetry.propagation.inject(carrier)
    carrier.compact
  rescue StandardError
    {}
  end

  def with_context(carrier)
    context = OpenTelemetry.propagation.extract(carrier.compact)
    OpenTelemetry::Context.with_current(context) { yield }
  rescue StandardError
    yield
  end
end
