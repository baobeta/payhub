# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261021500001_guard_twin_parent_and_one_owner")

# TC-M10-3: the deploy stops with the offending ids before it installs
# triggers the existing data would already break (RUNBOOK: "One owner").
RSpec.describe GuardTwinParentAndOneOwner do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }

  it "TC-M10-3 passes on clean data" do
    merchant = create(:merchant)
    create(:merchant_user, merchant:, role: "owner")

    expect { migration.preflight! }.not_to raise_error
  end

  it "TC-M10-3 names a live merchant whose active members have no active owner" do
    ownerless = create(:merchant)
    create(:merchant_user, merchant: ownerless, role: "admin") # the deferred owner trigger never fires in a test transaction

    expect { migration.preflight! }.to raise_error(RuntimeError, /no active owner.*#{ownerless.id}/m)
  end

  it "TC-M10-3 names a test twin whose parent is not a live merchant" do
    first_twin = create(:merchant).test_twin!
    # A twin of a twin: what the trigger refuses, so switch it off inside this
    # example's transaction (rolled back with it).
    ActiveRecord::Base.connection.execute("ALTER TABLE merchants DISABLE TRIGGER trg_merchants_twin_parent_is_live")
    twin = create(:merchant, livemode: false, live_merchant_id: first_twin.id)

    expect { migration.preflight! }.to raise_error(RuntimeError, /parent is not live.*#{twin.id}/m)
  end
end
