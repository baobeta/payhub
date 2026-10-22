# typed: true

# Like prometheus/client/formats/text, the gem does not require its file store
# from its main file, so tapioca's gem RBI does not include it.
class Prometheus::Client::DataStores::DirectFileStore
  sig { params(dir: String).void }
  def initialize(dir:); end
end
