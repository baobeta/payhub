# typed: true

# opentelemetry-api does not ship RBI definitions, so declare the namespaces
# and methods referenced by the tracing facade. Return types stay untyped:
# runtime behavior remains owned by the gem.
module OpenTelemetry
  def self.tracer_provider; end
  def self.propagation; end

  module SDK
    def self.configure; end

    # Used by spec/support/span_capture.rb to assert on trace shape.
    module Trace
      module Export
        class InMemorySpanExporter; end
        class SimpleSpanProcessor; end
      end
    end
  end

  module Trace
    def self.current_span(context = nil); end

    class Link
      def initialize(span_context, attributes = nil); end
    end
  end
end
