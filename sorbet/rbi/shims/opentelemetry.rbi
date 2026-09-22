# typed: true

# opentelemetry-api does not ship RBI definitions, so declare the namespaces
# referenced by the tracing facade. Runtime behavior remains owned by the gem.
module OpenTelemetry
  module Trace; end
end
