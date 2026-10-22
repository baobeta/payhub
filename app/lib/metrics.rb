# typed: strict
# frozen_string_literal: true

require "prometheus/client"

# Prometheus-style counters for /metrics. Names and labels are fixed here so
# a typo cannot create a new series at runtime. Phase 8 wires /metrics and
# the request/job instrumentation; this is the registry they share.
module Metrics
  extend T::Sig

  REGISTRY = T.let(Prometheus::Client.registry, Prometheus::Client::Registry)

  COUNTERS = T.let(
    {
      payments_created: [:psp, :currency],
      psp_calls: [:psp, :operation, :outcome],
      webhook_deliveries: [:attempt],
      webhook_duplicates: [:psp],
      webhook_signature_failures: [:psp],
      late_success: [:psp],
      orphan_webhooks_abandoned: [:psp],
      stuck_payment_alerts: [:psp, :state],
      psp_never_received: [:psp],
      authorizations_expired: [:psp],
      psp_circuit_opened: [:psp],
      settlement_discrepancies: [:psp, :status],
      ledger_imbalance_detected: [],
      psp_call_log_failures: [:psp],
      psp_call_in_transaction: [:psp],
      authz_denied: [:area, :permission],
      audit_write_failed: [:area],
      authz_undeclared: [:controller],
      tenant_not_found: [:area],
      auth_failed: [:area, :factor]
    }.freeze,
    T::Hash[Symbol, T::Array[Symbol]]
  )

  # Gauges: a current value, not a rate. Set on every sweep and scrape. With the
  # file store (config/initializers/prometheus.rb) a scrape reports the value
  # set most recently by any process: a sum would multiply it, and a max would
  # keep a stale high value from a process that has not set it since.
  GAUGES = T.let(
    { unknown_state_payments: [], outbound_events_pending: [], outbound_events_dead: [] }.freeze,
    T::Hash[Symbol, T::Array[Symbol]]
  )

  class << self
    extend T::Sig

    sig { params(name: Symbol, labels: T.untyped).void }
    def increment(name, **labels)
      counter(name).increment(labels: labels)
    end

    sig { params(name: Symbol, value: Numeric, labels: T.untyped).void }
    def gauge(name, value, **labels)
      label_names = GAUGES.fetch(name) { raise ArgumentError, "unknown gauge #{name.inspect}" }
      # The in-process store (PROMETHEUS_MULTIPROC_DIR unset) refuses any store
      # settings; aggregation only applies to the file store (RUNBOOK "Metrics across processes").
      settings = Prometheus::Client.config.data_store.is_a?(Prometheus::Client::DataStores::DirectFileStore) ? { aggregation: :most_recent } : {}
      g = REGISTRY.get(:"payhub_#{name}") ||
          REGISTRY.gauge(:"payhub_#{name}", docstring: name.to_s.tr("_", " "), labels: label_names,
                                            store_settings: settings)
      g.set(value, labels: labels)
    end

    # Called at boot (config/initializers/prometheus.rb). A scrape lists only
    # the metrics registered in the process serving it (then reads every
    # process's files for them), so a counter raised only in another Puma
    # worker or Sidekiq process would otherwise be missing. Gauges stay lazy:
    # registering an unlabelled one writes 0 for this process, which as the
    # :most_recent value would hide what the sweeper set; each process that
    # serves a scrape sets its own gauges (MetricsController, the sweepers).
    sig { void }
    def register_counters!
      COUNTERS.each_key { |name| counter(name) }
    end

    # Called at boot (config/initializers/prometheus.rb). With Puma workers
    # and no file store, each scrape sees only the worker that answered it.
    sig { params(web_concurrency: T.nilable(String), multiproc_dir: T.nilable(String)).void }
    def warn_if_per_process_in_production(web_concurrency: ENV.fetch("WEB_CONCURRENCY", nil),
                                          multiproc_dir: ENV.fetch("PROMETHEUS_MULTIPROC_DIR", nil))
      return unless Rails.env.production? && web_concurrency.to_i.positive? && multiproc_dir.blank?

      Rails.logger.warn("PROMETHEUS_MULTIPROC_DIR is not set but WEB_CONCURRENCY is: metrics are per-process, " \
                        "so each scrape sees only the Puma worker that answered it")
    end

    sig { params(name: Symbol).returns(Prometheus::Client::Counter) }
    def counter(name)
      label_names = COUNTERS.fetch(name) { raise ArgumentError, "unknown metric #{name.inspect}" }
      REGISTRY.get(:"payhub_#{name}_total") ||
        REGISTRY.counter(:"payhub_#{name}_total", docstring: name.to_s.tr("_", " "), labels: label_names)
    end
  end
end
