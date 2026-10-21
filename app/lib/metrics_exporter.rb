# typed: true
# frozen_string_literal: true

require "prometheus/client/formats/text"
require "puma"
require "puma/server"

# GET /metrics for a process that serves no HTTP of its own (Sidekiq), so the
# counters raised in jobs reach the scrape. Same registry and token rule as
# MetricsController (MetricsAuth). Unlike the controller it does not refresh
# the DB-backed gauges on scrape: the sweepers set them, and the web scrape
# already queries them, so the worker would only repeat the queries.
module MetricsExporter
  extend T::Sig

  sig { params(token: T.nilable(String)).returns(T.proc.params(env: T::Hash[String, T.untyped]).returns(T::Array[T.untyped])) }
  def self.rack_app(token: ENV["METRICS_TOKEN"])
    lambda do |env|
      unless MetricsAuth.authorized?(env["HTTP_AUTHORIZATION"], token:)
        next [401, { "content-type" => "text/plain", "www-authenticate" => 'Bearer realm="metrics"' }, ["unauthorized"]]
      end
      next [404, { "content-type" => "text/plain" }, ["not found"]] unless env["PATH_INFO"] == "/metrics"

      [200, { "content-type" => Prometheus::Client::Formats::Text::CONTENT_TYPE },
       [Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY)]]
    end
  end

  # Serves rack_app from an in-process Puma on background threads. Called from
  # Sidekiq's startup hook (config/initializers/sidekiq.rb), which re-raises,
  # so this never raises: a bad host or port, or a port in use, logs an error
  # and returns nil. Losing the worker's metrics is not worth stopping the jobs.
  # Otherwise returns the server so the caller can stop it.
  #
  # Uses Puma's embedded-server internals, not its CLI: Server.new(app, nil,
  # options), add_tcp_listener, run and stop. The real-socket example in
  # spec/lib/metrics_exporter_spec.rb is what catches a Puma upgrade breaking them.
  sig do
    params(host: String, port: T.any(String, Integer), token: T.nilable(String)).returns(T.nilable(Puma::Server))
  end
  def self.start!(host: ENV.fetch("WORKER_METRICS_HOST", "0.0.0.0"),
                  port: ENV.fetch("WORKER_METRICS_PORT", "9394"),
                  token: ENV["METRICS_TOKEN"])
    server = Puma::Server.new(rack_app(token:), nil,
                              min_threads: 0, max_threads: 2, force_shutdown_after: 5,
                              log_writer: Puma::LogWriter.null)
    server.add_tcp_listener(host, Integer(port))
    server.run
    Rails.logger.info("Worker metrics on http://#{host}:#{port}/metrics")
    server
  rescue StandardError => e
    Rails.logger.error("Worker metrics disabled (#{host}:#{port}): #{e.class}: #{e.message}")
    nil
  end
end
