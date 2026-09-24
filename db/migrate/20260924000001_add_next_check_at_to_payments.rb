class AddNextCheckAtToPayments < ActiveRecord::Migration[7.2]
  # The index is built CONCURRENTLY: payments is the big table (1M rows in the
  # perf proof) and a plain CREATE INDEX would block every write while it runs.
  disable_ddl_transaction!

  def change
    # When the sweeper should next poll this payment, and how many times it
    # already has. NULL means "never polled": due STUCK_AFTER after the last
    # state change (DECISIONS #13).
    add_column :payments, :next_check_at, :datetime
    add_column :payments, :check_attempts, :integer, null: false, default: 0

    add_index :payments, "COALESCE(next_check_at, updated_at + interval '2 minutes')",
              name: "index_payments_on_sweeper_due_at",
              where: "state IN ('pending', 'unknown')",
              algorithm: :concurrently
  end
end
