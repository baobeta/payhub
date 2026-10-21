# frozen_string_literal: true

require "rails_helper"
require "prometheus/client/formats/text"

RSpec.describe Metrics do
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
      pid = fork do
        described_class.increment(:webhook_duplicates, psp: "nordpay")
        described_class.gauge(:unknown_state_payments, 3)
        exit!(0)
      end
      child_ok = Process.wait2(pid).last.success?

      text = Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY)
      expect(child_ok).to be(true)
      expect(text).to include('payhub_webhook_duplicates_total{psp="nordpay"} 2.0')
      expect(text).to include("payhub_unknown_state_payments 3.0")
    end
  ensure
    Prometheus::Client.config.data_store = original_store
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
