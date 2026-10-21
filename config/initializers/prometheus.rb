# typed: false
# frozen_string_literal: true

require "prometheus/client/data_stores/direct_file_store"

# Every process (each Puma worker, each Sidekiq process) writes its metrics to
# files in one directory; /metrics sums counters and reports each gauge's most
# recently set value (see Metrics::GAUGES).
# The directory must be wiped when the container starts, or a restart keeps
# the old processes' values. Unset, each process keeps its own in memory.
# Must run before any metric is created: a metric binds to the store it was
# created with (Metrics creates them on first use).
if (dir = ENV["PROMETHEUS_MULTIPROC_DIR"].presence)
  FileUtils.mkdir_p(dir)
  Prometheus::Client.config.data_store = Prometheus::Client::DataStores::DirectFileStore.new(dir:)
end
