# typed: true

# opentelemetry-api does not ship RBI definitions, so declare the namespaces
# referenced by the tracing facade. Runtime behavior remains owned by the gem.
module OpenTelemetry
  module SDK
    def self.configure; end
  end

  module Context
    def self.with_current(context); end
  end

  module Trace; end
end
