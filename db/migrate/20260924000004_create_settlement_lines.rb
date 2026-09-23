class CreateSettlementLines < ActiveRecord::Migration[7.2]
  # Settlement-file reconciliation (DECISIONS #18): every line of a PSP's
  # settlement report, stored once, matched to our books, and — when it
  # matches — booked to the ledger, clearing psp_receivable.
  def up
    create_table :settlement_lines, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :psp_name, null: false
      t.string :external_id, null: false # the PSP's line id
      t.date :settled_on, null: false
      t.string :kind, null: false # capture | refund
      t.string :psp_reference, null: false
      t.string :refund_reference
      t.references :payment, type: :uuid, foreign_key: true
      t.references :refund, type: :uuid, foreign_key: true
      t.bigint :gross_minor, null: false
      t.bigint :fee_minor, null: false
      t.bigint :net_minor, null: false
      t.string :currency, limit: 3, null: false
      t.datetime :booked_at, null: false
      t.string :status, null: false # matched | unmatched | mismatch
      t.string :problem
      t.datetime :created_at, null: false
    end
    # A line is ingested once, however often the report is fetched.
    add_index :settlement_lines, %i[psp_name external_id], unique: true
    add_index :settlement_lines, :status, where: "status <> 'matched'"
    execute <<~SQL
      ALTER TABLE settlement_lines ADD CONSTRAINT chk_settlement_lines_kind CHECK (kind IN ('capture', 'refund'));
      ALTER TABLE settlement_lines ADD CONSTRAINT chk_settlement_lines_status CHECK (status IN ('matched', 'unmatched', 'mismatch'));

      ALTER TABLE ledger_accounts DROP CONSTRAINT chk_ledger_accounts_kind;
      ALTER TABLE ledger_accounts ADD CONSTRAINT chk_ledger_accounts_kind
        CHECK (kind IN ('psp_receivable', 'merchant_payable', 'refunds_reserved', 'refunds_paid', 'psp_payouts', 'psp_fees'));
    SQL
  end

  def down
    drop_table :settlement_lines
    execute <<~SQL
      ALTER TABLE ledger_accounts DROP CONSTRAINT chk_ledger_accounts_kind;
      ALTER TABLE ledger_accounts ADD CONSTRAINT chk_ledger_accounts_kind
        CHECK (kind IN ('psp_receivable', 'merchant_payable', 'refunds_reserved', 'refunds_paid'));
    SQL
  end
end
