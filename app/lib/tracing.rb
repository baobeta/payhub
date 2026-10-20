# typed: true
# frozen_string_literal: true

require "opentelemetry-api"

module Tracing
  extend T::Sig

  module_function

  sig { returns(T.untyped) }
  def tracer
    OpenTelemetry.tracer_provider.tracer("payhub")
  end

  sig do
    type_parameters(:R)
      .params(
        name: String,
        attributes: T::Hash[String, T.untyped],
        links: T.nilable(T::Array[OpenTelemetry::Trace::Link]),
        blk: T.proc.params(span: T.untyped).returns(T.type_parameter(:R))
      )
      .returns(T.type_parameter(:R))
  end
  def in_span(name, attributes: {}, links: nil, &blk)
    tracer.in_span(name, attributes: attributes.compact, links: links) do |span|
      yield span
    end
  end

  sig { params(attributes: T::Hash[String, T.untyped]).void }
  def add_attributes(attributes)
    OpenTelemetry::Trace.current_span.add_attributes(attributes.compact)
  rescue StandardError
    nil
  end

  # The current context as a W3C traceparent, for work that will run later in
  # another trace (see OutboundEvent.emit!).
  sig { returns(T.nilable(String)) }
  def current_traceparent
    carrier = {}
    OpenTelemetry.propagation.inject(carrier)
    carrier["traceparent"]
  rescue StandardError
    nil
  end

  # A span link to a stored traceparent, or nil when there is nothing valid to link to.
  sig { params(traceparent: T.nilable(String)).returns(T.nilable(T::Array[OpenTelemetry::Trace::Link])) }
  def links_from(traceparent)
    return nil if traceparent.blank?

    context = OpenTelemetry::Trace.current_span(OpenTelemetry.propagation.extract({ "traceparent" => traceparent })).context
    context.valid? ? [OpenTelemetry::Trace::Link.new(context)] : nil
  rescue StandardError
    nil
  end

  sig { returns(T::Hash[Symbol, String]) }
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
