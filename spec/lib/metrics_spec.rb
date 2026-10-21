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
      Process.wait(pid)

      text = Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY)
      expect($CHILD_STATUS.success?).to be(true)
      expect(text).to include('payhub_webhook_duplicates_total{psp="nordpay"} 2.0')
      expect(text).to include("payhub_unknown_state_payments 3.0")
    end
  ensure
    Prometheus::Client.config.data_store = original_store
  end
end
