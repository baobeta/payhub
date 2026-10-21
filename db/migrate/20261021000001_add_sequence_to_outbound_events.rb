# frozen_string_literal: true

# A per-payment counter on each outbound event (TEST_CASES H8), so a merchant
# can drop an update older than one it already applied — delivery is
# at-least-once and unordered (Adyen's sequenceNumber). Assigned in
# OutboundEvent.emit! under the payment row lock; the unique index is the
# backstop if a caller ever emits without it.
#
# TC-H8-3: outbound_events is large and written on every payment change, so
# nothing here holds a long lock. No DDL transaction; the nullable column is
# a catalog-only change; the backfill commits in batches; the index builds
# CONCURRENTLY (writes continue while it builds).
class AddSequenceToOutboundEvents < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  BATCH_SIZE = 5_000
  INDEX = "idx_outbound_events_payment_sequence"

  def up
    add_column :outbound_events, :sequence, :integer, if_not_exists: true
    say "backfilled outbound_events.sequence in #{backfill_sequences} batches of up to #{BATCH_SIZE} rows"
    add_index :outbound_events, %i[payment_id sequence], unique: true, where: "payment_id IS NOT NULL",
                                                         name: INDEX, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :outbound_events, name: INDEX, algorithm: :concurrently, if_exists: true
    remove_column :outbound_events, :sequence, if_exists: true
  end

  # Numbers each payment's events 1..n by (created_at, id), BATCH_SIZE
  # unnumbered rows per transaction, until none is left. Each batch numbers
  # its rows across their payment's whole history, so a payment split over
  # two batches still counts 1..n; rows the old code inserts meanwhile are
  # picked up by a later batch. Rerunnable after a failure. Returns the
  # number of batches.
  def backfill_sequences(batch_size: BATCH_SIZE)
    batches = 0
    loop do
      updated = connection.transaction do
        connection.exec_update(<<~SQL.squish)
          WITH batch AS (
            SELECT id, payment_id FROM outbound_events
            WHERE payment_id IS NOT NULL AND sequence IS NULL
            ORDER BY id LIMIT #{Integer(batch_size)}
          ), numbered AS (
            SELECT id, row_number() OVER (PARTITION BY payment_id ORDER BY created_at, id) AS n
            FROM outbound_events WHERE payment_id IN (SELECT payment_id FROM batch)
          )
          UPDATE outbound_events SET sequence = numbered.n
          FROM numbered
          WHERE outbound_events.id = numbered.id AND outbound_events.id IN (SELECT id FROM batch)
        SQL
      end
      break if updated.zero?

      batches += 1
    end
    batches
  end
end
