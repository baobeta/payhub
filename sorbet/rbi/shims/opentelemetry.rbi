# typed: true

# opentelemetry-api does not ship RBI definitions, so declare the namespaces
# referenced by the tracing facade. Runtime behavior remains owned by the gem.
module OpenTelemetry
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

  module Trace; end
end
