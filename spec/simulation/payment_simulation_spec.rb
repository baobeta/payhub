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
end
