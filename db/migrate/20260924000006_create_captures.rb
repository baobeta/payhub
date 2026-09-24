class CreateCaptures < ActiveRecord::Migration[7.2]
  # Each capture request is a row (DECISIONS #20), so CapturePaymentJob can be
  # idempotent against a PSP whose capture call is not.
  def up
    create_table :captures, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :payment, type: :uuid, null: false, foreign_key: true, index: false
      t.bigint :amount_minor, null: false
      # The ledger's captured total when the request was accepted. The capture
      # has landed at the PSP once its running total reaches base + amount.
      t.bigint :base_captured_minor, null: false
      t.string :state, null: false, default: "pending"
      t.string :failure_code
      t.timestamps
    end
    # One capture in flight per payment: that is what makes "has it landed?"
    # answerable from the PSP's running total alone.
    add_index :captures, :payment_id, unique: true, where: "state = 'pending'", name: "idx_captures_one_pending_per_payment"
    add_index :captures, %i[payment_id created_at]
    execute <<~SQL
      ALTER TABLE captures ADD CONSTRAINT chk_captures_state CHECK (state IN ('pending', 'succeeded', 'failed'));
      ALTER TABLE captures ADD CONSTRAINT chk_captures_amount_positive CHECK (amount_minor > 0);
    SQL
  end

  def down
    drop_table :captures
  end
end
