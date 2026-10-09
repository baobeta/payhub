# frozen_string_literal: true

require "rails_helper"

RSpec.describe DemoChaosRunJob do
  before { create(:merchant, name: DemoMerchant::NAME, livemode: true) }

  def issued_key(run) = ApiKey.find_by(name: "Demo chaos run #{run.id}")

  def run_with(result)
    run = DemoChaosRun.create!(payments: 5)
    allow(ChaosRun).to receive(:new).and_return(instance_double(ChaosRun, call: result))
    run
  end

  it "marks the run running, then passed, and revokes the throwaway key" do
    run = run_with({ passed: true, checks: [], final_states: {}, unknown_transitions: 0 })

    described_class.perform_now(run.id)

    run.reload
    expect(run.state).to eq("passed")
    expect(run.result).to eq("passed" => true, "checks" => [], "final_states" => {}, "unknown_transitions" => 0)
    expect(run.finished_at).to be_present
    expect(issued_key(run).revoked_at).to be_present, "throwaway key must be revoked"
  end

  it "records a failed run and still revokes the key" do
    run = run_with({ passed: false, checks: [{ label: "x", passed: false }] })

    described_class.perform_now(run.id)

    expect(run.reload.state).to eq("failed")
    expect(issued_key(run).revoked_at).to be_present
  end

  it "records an error, revokes the key, and re-raises" do
    run = DemoChaosRun.create!(payments: 5)
    allow(ChaosRun).to receive(:new).and_raise(RuntimeError, "the PSP is unreachable")

    expect { described_class.perform_now(run.id) }.to raise_error(RuntimeError, "the PSP is unreachable")
    expect(run.reload.state).to eq("errored")
    expect(run.error).to eq("RuntimeError")
    expect(issued_key(run).revoked_at).to be_present
  end
end
