# frozen_string_literal: true

# Keeps finished spans in memory so specs can assert on trace shape
# (parentage, trace IDs), not just on the IDs that reach log lines.
SPAN_EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry.tracer_provider.add_span_processor(
  OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(SPAN_EXPORTER)
)

RSpec.configure do |config|
  config.before { SPAN_EXPORTER.reset }
end
