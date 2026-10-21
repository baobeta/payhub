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
  # Sidekiq's startup hook (config/initializers/sidekiq.rb). Returns the server
  # so the caller can stop it, or nil when the port can't be bound: losing the
  # worker's metrics is not worth stopping the jobs.
  sig do
    params(host: String, port: Integer, token: T.nilable(String)).returns(T.nilable(Puma::Server))
  end
  def self.start!(host: ENV.fetch("WORKER_METRICS_HOST", "0.0.0.0"),
                  port: Integer(ENV.fetch("WORKER_METRICS_PORT", "9394")),
                  token: ENV["METRICS_TOKEN"])
    server = Puma::Server.new(rack_app(token:), nil, min_threads: 0, max_threads: 2, log_writer: Puma::LogWriter.null)
    server.add_tcp_listener(host, port)
    server.run
    Rails.logger.info("Worker metrics on http://#{host}:#{port}/metrics")
    server
  rescue SystemCallError => e
    Rails.logger.error("Worker metrics could not listen on #{host}:#{port}: #{e.message}")
    nil
  end
end
