require "rails_helper"

# The one rule under seeded faults (DECISIONS #19). The engine and its
# invariants are in spec/support/payment_simulation.rb, the PSP in sim_psp.rb.
#
#   SIM_SEED=123 bundle exec rspec spec/simulation     # replay one run exactly
#   SIM_RUNS=50 SIM_STEPS=300 bundle exec rspec spec/simulation
RSpec.describe PaymentSimulation do
  ENV.fetch("SIM_RUNS", 4).to_i.times do |run|
    it "keeps the one rule under seeded faults, run ##{run}" do
      simulation = described_class.new(seed: ENV["SIM_SEED"]&.to_i || Random.new_seed, merchant: create(:merchant),
                                       travel_to: method(:travel_to), jobs: ActiveJob::Base.queue_adapter)
      allow(PspRouter).to receive(:adapter).and_return(simulation.psp)
      allow(Rails.logger).to receive(:error) # expected under faults; the invariants are the judge

      outcome = simulation.run(steps: ENV.fetch("SIM_STEPS", 150).to_i)

      expect(outcome).to be_ok, outcome.report
    end
  end

  # TC-E3-19: multicapture is exercised, not swallowed. Every run above
  # already fails on a capture refused with an unexpected code. Here, a run on
  # a fixed seed (so it cannot flake) must also land later captures: a random
  # 150-step run makes only a handful of captures and may honestly land none.
  it "TC-E3-19: lands second captures, and refuses only with expected codes" do
    simulation = described_class.new(seed: 1, merchant: create(:merchant), travel_to: method(:travel_to),
                                     jobs: ActiveJob::Base.queue_adapter)
    allow(PspRouter).to receive(:adapter).and_return(simulation.psp)
    allow(Rails.logger).to receive(:error)

    outcome = simulation.run(steps: 150)

    expect(outcome).to be_ok, outcome.report
    expect(outcome.captures.keys - %i[accepted accepted_again closed later_succeeded])
      .to all(be_in(described_class::EXPECTED_CAPTURE_REFUSALS))
    expect(outcome.captures[:later_succeeded]).to be_positive, outcome.captures.to_s
  end

  # TC-C9-1: the double-charge rule (DECISIONS #12) against a PSP that, like
  # Kiripay, makes a new charge for every authorize POST and whose lookups lag.
  # Fixed seeds so it cannot flake; every run also holds the usual invariants.
  (1..10).each do |seed|
    it "TC-C9-1: a Kiripay-like PSP holds at most one charge per payment reference, seed #{seed}" do
      create(:fx_rate, base: "VND", quote: "EUR", captured_at: Time.utc(2026, 1, 1))
      simulation = described_class.new(seed:, merchant: create(:merchant), travel_to: method(:travel_to),
                                       jobs: ActiveJob::Base.queue_adapter, kiripay_like: true)
      allow(PspRouter).to receive(:adapter).and_return(simulation.psp)
      allow(Rails.logger).to receive(:error)

      outcome = simulation.run(steps: 150)

      expect(simulation.psp.duplicate_charges).to be_empty
      expect(outcome).to be_ok, outcome.report
    end
  end
end
