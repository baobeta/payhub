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
      stuck_payment_alerts: [:psp, :state],
      authorizations_expired: [:psp],
      psp_circuit_opened: [:psp],
      settlement_discrepancies: [:psp, :status],
      ledger_imbalance_detected: [],
      psp_call_log_failures: [:psp],
      authz_denied: [:area, :permission],
      authz_undeclared: [:controller],
      tenant_not_found: [:area],
      auth_failed: [:area, :factor]
    }.freeze,
    T::Hash[Symbol, T::Array[Symbol]]
  )

  # Gauges: a current value, not a rate. Set on every sweep.
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
      g = REGISTRY.get(:"payhub_#{name}") ||
          REGISTRY.gauge(:"payhub_#{name}", docstring: name.to_s.tr("_", " "), labels: label_names)
      g.set(value, labels: labels)
    end

    sig { params(name: Symbol).returns(Prometheus::Client::Counter) }
    def counter(name)
      label_names = COUNTERS.fetch(name) { raise ArgumentError, "unknown metric #{name.inspect}" }
      REGISTRY.get(:"payhub_#{name}_total") ||
        REGISTRY.counter(:"payhub_#{name}_total", docstring: name.to_s.tr("_", " "), labels: label_names)
    end
  end
end
