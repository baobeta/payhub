class CreateLedger < ActiveRecord::Migration[7.2]
  def up
    create_table :ledger_accounts, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :merchant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :currency, limit: 3, null: false
      t.datetime :created_at, null: false
    end

    add_check_constraint :ledger_accounts,
                         "kind IN ('psp_receivable', 'merchant_payable', 'refunds_paid')",
                         name: "chk_ledger_accounts_kind"
    add_index :ledger_accounts, [ :merchant_id, :kind, :currency ], unique: true,
              name: "idx_ledger_accounts_unique"

    # No updated_at on purpose: nothing here is ever changed.
    create_table :ledger_entries, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      # Groups the legs of one movement. Legs per transfer_id MUST sum to zero per currency.
      t.uuid :transfer_id, null: false
      t.references :account, type: :uuid, null: false, foreign_key: { to_table: :ledger_accounts }, index: false
      # Which payment/refund this leg belongs to, so per-payment sums are one indexed query.
      t.references :payment, type: :uuid, foreign_key: true
      t.references :refund, type: :uuid, foreign_key: true, index: false

      t.string :direction, null: false
      # Sign comes from direction, never from the number.
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false

      t.datetime :created_at, null: false
    end

    add_check_constraint :ledger_entries, "direction IN ('debit', 'credit')", name: "chk_ledger_entries_direction"
    add_check_constraint :ledger_entries, "amount_minor > 0", name: "chk_ledger_entries_amount_positive"

    add_index :ledger_entries, :transfer_id, name: "idx_ledger_entries_transfer"
    add_index :ledger_entries, [ :account_id, :currency ], name: "idx_ledger_entries_balance"

    # Append-only, enforced by the database: any UPDATE or DELETE raises.
    # Corrections are new reversing entries.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION ledger_entries_immutable() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'ledger_entries is append-only (attempted %)', TG_OP;
      END
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER trg_ledger_entries_immutable
        BEFORE UPDATE OR DELETE ON ledger_entries
        FOR EACH ROW EXECUTE FUNCTION ledger_entries_immutable();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_ledger_entries_immutable ON ledger_entries"
    execute "DROP FUNCTION IF EXISTS ledger_entries_immutable()"
    drop_table :ledger_entries
    drop_table :ledger_accounts
  end
end
