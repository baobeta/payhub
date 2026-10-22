# frozen_string_literal: true

require "rails_helper"
require "prometheus/client/formats/text"

RSpec.describe Metrics do
  # Runs the block in a forked child and returns whether it succeeded. The
  # child always leaves through exit!, even when the block raises, so it never
  # runs the at_exit hooks it inherited (RSpec's, SimpleCov's).
  def in_child
    Process.wait2(fork do
      yield
      exit!(0)
    rescue Exception # rubocop:disable Lint/RescueException
      exit!(1)
    end).last.success?
  end

  # When PROMETHEUS_MULTIPROC_DIR is unset the default Synchronized store is
  # used. Synchronized rejects any store_settings, so gauge writes must not
  # pass them in that case.
  it "PR-4: a gauge write succeeds under the Synchronized (in-process) store" do
    original_store = Prometheus::Client.config.data_store
    Prometheus::Client.config.data_store = Prometheus::Client::DataStores::Synchronized.new
    stub_const("Metrics::REGISTRY", Prometheus::Client::Registry.new)

    expect { described_class.gauge(:unknown_state_payments, 42) }.not_to raise_error
    expect(described_class::REGISTRY.get(:payhub_unknown_state_payments).get).to eq(42)
  ensure
    Prometheus::Client.config.data_store = original_store
  end

  it "PR-4: the registry uses the file store when PROMETHEUS_MULTIPROC_DIR is set" do
    expect(Prometheus::Client.config.data_store).to be_a(Prometheus::Client::DataStores::DirectFileStore)
  end

  # Two real processes write to one store directory; the scrape must sum the
  # counter and report the gauge the child set last (a max would say 7, a sum
  # 10). Runs against a private directory and registry so the values it leaves
  # behind never reach other examples.
  it "PR-4: a scrape sums counters and reports the latest gauge across processes" do
    skip "needs fork" unless Process.respond_to?(:fork)

    original_store = Prometheus::Client.config.data_store
    Dir.mktmpdir("prometheus-fork") do |dir|
      Prometheus::Client.config.data_store = Prometheus::Client::DataStores::DirectFileStore.new(dir:)
      stub_const("Metrics::REGISTRY", Prometheus::Client::Registry.new)

      described_class.increment(:webhook_duplicates, psp: "nordpay")
      described_class.gauge(:unknown_state_payments, 7)
      child_ok = in_child do
        described_class.increment(:webhook_duplicates, psp: "nordpay")
        described_class.gauge(:unknown_state_payments, 3)
      end

      text = Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY)
      expect(child_ok).to be(true)
      expect(text).to include('payhub_webhook_duplicates_total{psp="nordpay"} 2.0')
      expect(text).to include("payhub_unknown_state_payments 3.0")
    end
  ensure
    Prometheus::Client.config.data_store = original_store
  end

  describe "PR-4: counters registered at boot" do
    # A private store directory and registry, as a freshly booted process has.
    def with_private_store
      original_store = Prometheus::Client.config.data_store
      Dir.mktmpdir("prometheus-boot") do |dir|
        Prometheus::Client.config.data_store = Prometheus::Client::DataStores::DirectFileStore.new(dir:)
        stub_const("Metrics::REGISTRY", Prometheus::Client::Registry.new)
        yield
      end
    ensure
      Prometheus::Client.config.data_store = original_store
    end

    def scrape = Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY)

    # A scrape lists only metrics registered in the process serving it, then
    # reads every process's files for them.
    it "PR-4: a counter only another process incremented reaches this process's scrape" do
      skip "needs fork" unless Process.respond_to?(:fork)

      with_private_store do
        described_class.register_counters!
        child_ok = in_child { described_class.increment(:late_success, psp: "kiripay") }

        expect(child_ok).to be(true)
        expect(scrape).to include('payhub_late_success_total{psp="kiripay"} 1.0')
      end
    end

    it "PR-4: registering twice is harmless and registers every counter once" do
      with_private_store do
        described_class.register_counters!
        expect { described_class.register_counters! }.not_to raise_error
        expect(Metrics::REGISTRY.metrics.map(&:name))
          .to match_array(described_class::COUNTERS.keys.map { |name| :"payhub_#{name}_total" })
      end
    end

    it "PR-4: an unlabelled counter reads 0 before any increment" do
      with_private_store do
        described_class.register_counters!
        expect(scrape).to include("payhub_ledger_imbalance_detected_total 0.0")
      end
    end

    # Registering an unlabelled gauge writes 0 for this process, and with
    # :most_recent that 0 would hide the value the sweeper set until it next
    # ran, so a console or runner booting next to Sidekiq must not register gauges.
    it "PR-4: another process booting does not reset a gauge" do
      skip "needs fork" unless Process.respond_to?(:fork)

      with_private_store do
        described_class.gauge(:unknown_state_payments, 5)
        child_ok = in_child do
          stub_const("Metrics::REGISTRY", Prometheus::Client::Registry.new)
          described_class.register_counters!
        end

        expect(child_ok).to be(true)
        expect(scrape).to include("payhub_unknown_state_payments 5.0")
      end
    end
  end

  describe "PR-4: boot warning when Puma forks workers without the file store" do
    before { allow(Rails.logger).to receive(:warn) }

    def warn_with(concurrency:, dir:, production: true)
      allow(Rails.env).to receive(:production?).and_return(production)
      described_class.warn_if_per_process_in_production(web_concurrency: concurrency, multiproc_dir: dir)
    end

    it "PR-4: production with Puma workers and no directory logs one warning" do
      warn_with(concurrency: "2", dir: nil)
      expect(Rails.logger).to have_received(:warn).once.with(/PROMETHEUS_MULTIPROC_DIR.*per-process/)
    end

    it "PR-4: a blank directory counts as unset" do
      warn_with(concurrency: "2", dir: " ")
      expect(Rails.logger).to have_received(:warn).once
    end

    it "PR-4: a directory set logs nothing" do
      warn_with(concurrency: "2", dir: "/rails/tmp/prometheus")
      expect(Rails.logger).not_to have_received(:warn)
    end

    it "PR-4: a single process (no WEB_CONCURRENCY) logs nothing" do
      warn_with(concurrency: nil, dir: nil)
      expect(Rails.logger).not_to have_received(:warn)
    end

    it "PR-4: a blank or non-numeric WEB_CONCURRENCY neither raises nor warns" do
      expect { warn_with(concurrency: "", dir: nil) }.not_to raise_error
      expect { warn_with(concurrency: "abc", dir: nil) }.not_to raise_error
      expect(Rails.logger).not_to have_received(:warn)
    end

    it "PR-4: outside production nothing is logged" do
      warn_with(concurrency: "2", dir: nil, production: false)
      expect(Rails.logger).not_to have_received(:warn)
    end
  end
end
