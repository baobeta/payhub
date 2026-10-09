# frozen_string_literal: true

require "rails_helper"

RSpec.describe DemoChaosRun do
  it "refuses a second active run (partial unique index)" do
    described_class.create!(payments: 5) # defaults to state "queued"
    expect { described_class.create!(payments: 5) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a new run once the previous one finished" do
    described_class.create!(state: "passed", payments: 5)
    expect { described_class.create!(state: "queued", payments: 5) }.not_to raise_error
  end

  it "rejects a run of more than 20 payments in the database" do
    expect { described_class.create!(state: "queued", payments: 21) }
      .to raise_error(ActiveRecord::StatementInvalid, /chk_demo_chaos_runs_size/)
  end
end
