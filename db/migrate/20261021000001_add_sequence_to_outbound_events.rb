# frozen_string_literal: true

# A per-payment counter on each outbound event (TEST_CASES H8), so a merchant
# can drop an update older than one it already applied — delivery is
# at-least-once and unordered (Adyen's sequenceNumber). Assigned in
# OutboundEvent.emit! under the payment row lock; the unique index is the
# backstop if a caller ever emits without it.
class AddSequenceToOutboundEvents < ActiveRecord::Migration[8.0]
  def up
    add_column :outbound_events, :sequence, :integer
    execute <<~SQL.squish
      UPDATE outbound_events SET sequence = numbered.n
      FROM (SELECT id, row_number() OVER (PARTITION BY payment_id ORDER BY created_at, id) AS n
            FROM outbound_events WHERE payment_id IS NOT NULL) AS numbered
      WHERE outbound_events.id = numbered.id
    SQL
    add_index :outbound_events, %i[payment_id sequence], unique: true, where: "payment_id IS NOT NULL",
                                                         name: "idx_outbound_events_payment_sequence"
  end

  def down
    remove_column :outbound_events, :sequence
  end
end
