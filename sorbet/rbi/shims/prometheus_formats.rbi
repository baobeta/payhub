# typed: true

# prometheus-client loads prometheus/client/formats/text lazily (it is not
# required by the gem's main file), so tapioca's gem RBI does not include it.
module Prometheus::Client::Formats::Text
  CONTENT_TYPE = T.let(T.unsafe(nil), String)

  sig { params(registry: Prometheus::Client::Registry).returns(String) }
  def self.marshal(registry); end
end
