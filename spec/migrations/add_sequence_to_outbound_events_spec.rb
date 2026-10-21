# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261021000001_add_sequence_to_outbound_events")

# TC-H8-3: the backfill numbers each payment's events from 1 in created order,
# a batch at a time, so a large table is never locked in one UPDATE.
RSpec.describe AddSequenceToOutboundEvents do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }
  let(:merchant) { create(:merchant) }

  def event(payment, created_at)
    OutboundEvent.create!(merchant:, payment:, event_type: "payment.updated", payload: { "id" => "x" }, state: "delivered",
                          next_attempt_at: created_at, created_at:, sequence: nil)
  end

  it "TC-H8-3 numbers each payment's events 1..n by created_at across several batches, leaving payment-less events alone" do
    a = create(:payment, merchant:)
    b = create(:payment, merchant:)
    OutboundEvent.where(payment: [a, b]).delete_all # as before the migration: no row numbered yet
    t = Time.utc(2026, 10, 1)
    a3 = event(a, t + 3)
    b1 = event(b, t + 1)
    a1 = event(a, t + 1)
    b2 = event(b, t + 5)
    a2 = event(a, t + 2)
    orphan = OutboundEvent.create!(merchant:, payment: nil, event_type: "merchant.updated", payload: { "id" => "x" },
                                   state: "delivered", next_attempt_at: t)

    batches = migration.backfill_sequences(batch_size: 2)

    expect(batches).to eq(3)
    expect([a1, a2, a3, b1, b2, orphan].map { |e| e.reload.sequence }).to eq([1, 2, 3, 1, 2, nil])
  end

  it "TC-H8-3 is a no-op when every row is numbered already" do
    expect(migration.backfill_sequences(batch_size: 2)).to eq(0)
  end
end
