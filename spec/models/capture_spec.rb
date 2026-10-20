# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capture do
  let(:payment) { create(:payment) }

  describe "TC-E6-1: partial unique index allows one pending capture per payment" do
    it "TC-E6-1: raw insert of a second pending capture is rejected by the unique index" do
      # One pending capture is fine.
      payment.captures.create!(amount_minor: 1000, base_captured_minor: 0)
      expect(payment.captures.pending.count).to eq(1)

      # A second pending capture via raw SQL must be rejected.
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute(
            "INSERT INTO captures (id, payment_id, amount_minor, base_captured_minor, state, final, created_at, updated_at) " \
            "VALUES (gen_random_uuid(), '#{payment.id}', 500, 0, 'pending', false, NOW(), NOW())"
          )
        end
      end.to raise_error(ActiveRecord::RecordNotUnique, /idx_captures_one_pending_per_payment/)
    end

    it "allows a second capture once the first is no longer pending" do
      first = payment.captures.create!(amount_minor: 1000, base_captured_minor: 0)
      first.update!(state: "succeeded")

      expect { payment.captures.create!(amount_minor: 500, base_captured_minor: 1000) }.not_to raise_error
    end
  end
end
