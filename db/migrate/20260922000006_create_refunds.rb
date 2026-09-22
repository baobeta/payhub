class CreateRefunds < ActiveRecord::Migration[7.2]
  def change
    create_table :refunds, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :payment, type: :uuid, null: false, foreign_key: true

      t.string :state, null: false, default: "pending"
      t.bigint :amount_minor, null: false
      # Always equals payments.currency; stored so the row is self-describing.
      t.string :currency, limit: 3, null: false

      # Generated before the PSP call, same rule as payments.
      t.string :psp_reference, null: false
      t.string :reason
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_check_constraint :refunds, "amount_minor > 0", name: "chk_refunds_amount_positive"
    add_check_constraint :refunds, "state IN ('pending', 'succeeded', 'failed')", name: "chk_refunds_state"
    add_index :refunds, :psp_reference, unique: true, name: "idx_refunds_psp_ref"

    # NOT EXPRESSIBLE IN DDL: sum(amount_minor WHERE succeeded) <= captured amount.
    # It spans rows, so it is enforced in RefundService under SELECT ... FOR UPDATE
    # on the payment, checked against the LEDGER sum (DECISIONS #6).
  end
end
