class AddRefundReservationsToLedger < ActiveRecord::Migration[7.2]
  # Refund reservations move into the ledger as two-phase transfers
  # (DECISIONS #16): reserve on request, then post on PSP success or void on
  # failure. Irreversible: the backfilled rows are ledger entries, and the
  # ledger is append-only by trigger.
  def up
    execute <<~SQL
      ALTER TABLE ledger_accounts DROP CONSTRAINT chk_ledger_accounts_kind;
      ALTER TABLE ledger_accounts ADD CONSTRAINT chk_ledger_accounts_kind
        CHECK (kind IN ('psp_receivable', 'merchant_payable', 'refunds_reserved', 'refunds_paid'));
    SQL

    # One leg per (refund, account, direction). Reserve, post and void touch
    # different pairs, and post and void share `debit refunds_reserved` — so
    # the database itself refuses a second post, or a post after a void.
    add_index :ledger_entries, %i[refund_id account_id direction], unique: true,
              where: "refund_id IS NOT NULL", name: "idx_ledger_entries_refund_leg"

    # Refunds already in flight get their reservation now: the guard reads
    # reservations from the ledger from this deploy on.
    execute <<~SQL
      INSERT INTO ledger_accounts (merchant_id, kind, currency, created_at)
      SELECT DISTINCT p.merchant_id, 'refunds_reserved', r.currency, now()
      FROM refunds r JOIN payments p ON p.id = r.payment_id
      WHERE r.state = 'pending'
      ON CONFLICT DO NOTHING;

      WITH in_flight AS (
        SELECT r.id AS refund_id, r.payment_id, p.merchant_id, r.currency, r.amount_minor,
               gen_random_uuid() AS transfer_id
        FROM refunds r JOIN payments p ON p.id = r.payment_id
        WHERE r.state = 'pending'
      )
      INSERT INTO ledger_entries (transfer_id, account_id, payment_id, refund_id, direction, amount_minor, currency, created_at)
      SELECT f.transfer_id, a.id, f.payment_id, f.refund_id, leg.direction, f.amount_minor, f.currency, now()
      FROM in_flight f
      CROSS JOIN (VALUES ('merchant_payable', 'debit'), ('refunds_reserved', 'credit')) AS leg(kind, direction)
      JOIN ledger_accounts a ON a.merchant_id = f.merchant_id AND a.currency = f.currency AND a.kind = leg.kind;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
