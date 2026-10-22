require "rails_helper"

# Split from payment_simulation_spec.rb so CI's shards (bin/rspec-shard) can
# run these seeds beside the seeded-fault runs: together they took 90 s.
RSpec.describe PaymentSimulation do
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
