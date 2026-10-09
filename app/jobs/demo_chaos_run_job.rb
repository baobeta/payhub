# typed: true
# frozen_string_literal: true

# D-04. Runs a small chaos run against the demo twin with a throwaway test
# key. ChaosRun makes the Nordpay simulator hostile for its duration, which
# also affects other demo payments made meanwhile; the UI says so.
class DemoChaosRunJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = DemoChaosRun.find(run_id)
    run.update!(state: "running")
    key, raw = ApiKey.issue!(merchant: DemoMerchant.live, livemode: false, name: "Demo chaos run #{run.id}")
    begin
      result = ChaosRun.new(payments: run.payments, merchant: DemoMerchant.twin, api_key: raw, out: StringIO.new).call
      run.update!(state: result[:passed] ? "passed" : "failed", result:, finished_at: Time.current)
    ensure
      key.revoke!
    end
  rescue StandardError => e
    run&.update!(state: "errored", error: e.class.name, finished_at: Time.current)
    raise
  end
end
