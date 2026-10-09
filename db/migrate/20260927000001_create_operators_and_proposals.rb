class CreateOperatorsAndProposals < ActiveRecord::Migration[8.1]
  def up
    create_table :operators, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :email, null: false
      t.string :name
      t.string :password_digest
      t.string :role, null: false
      t.text :otp_secret
      t.datetime :otp_enabled_at
      t.bigint :otp_last_used_step
      t.integer :failed_attempts, null: false, default: 0
      t.datetime :locked_until
      t.uuid :invited_by_id
      t.string :invitation_digest
      t.datetime :invitation_expires_at
      t.datetime :accepted_at
      t.datetime :disabled_at
      t.timestamps
    end
    add_index :operators, "lower(email)", unique: true, name: "idx_operators_email"
    add_index :operators, :invitation_digest, unique: true, where: "invitation_digest IS NOT NULL"
    add_check_constraint :operators, "role IN ('support', 'ops', 'approver', 'admin')", name: "chk_operators_role"
    add_foreign_key :operators, :operators, column: :invited_by_id

    create_table :operator_proposals, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :kind, null: false
      t.references :payment, type: :uuid, null: false, foreign_key: true
      t.jsonb :payload, null: false
      t.string :reason_code, null: false
      t.text :reason_text, null: false
      t.string :case_reference, null: false
      t.string :client_token, null: false         # retried submit → same proposal
      t.references :proposed_by, type: :uuid, null: false, foreign_key: { to_table: :operators }
      t.string :state, null: false, default: "pending"
      t.references :decided_by, type: :uuid, foreign_key: { to_table: :operators }
      t.datetime :decided_at
      t.text :decision_note
      t.datetime :applied_at
      t.uuid :applied_transfer_id                 # ledger corrections: the transfer we posted
      t.string :error
      t.timestamps
    end
    add_index :operator_proposals, :client_token, unique: true
    add_index :operator_proposals, %i[state created_at]
    add_check_constraint :operator_proposals, "kind IN ('payment_transition', 'ledger_correction')", name: "chk_operator_proposals_kind"
    add_check_constraint :operator_proposals, "state IN ('pending', 'withdrawn', 'rejected', 'applied', 'failed')",
                         name: "chk_operator_proposals_state"
    add_check_constraint :operator_proposals, "decided_by_id IS NULL OR decided_by_id <> proposed_by_id",
                         name: "chk_operator_proposals_not_self"
    add_check_constraint :operator_proposals, "(state = 'pending') = (decided_at IS NULL) OR state = 'withdrawn'",
                         name: "chk_operator_proposals_decided_shape"

    # An approver approves exactly what they read (design §3, layer 4).
    execute <<~SQL
      CREATE FUNCTION operator_proposal_payload_immutable() RETURNS trigger AS $$
      BEGIN
        IF NEW.payload IS DISTINCT FROM OLD.payload OR NEW.kind IS DISTINCT FROM OLD.kind
           OR NEW.payment_id IS DISTINCT FROM OLD.payment_id OR NEW.proposed_by_id IS DISTINCT FROM OLD.proposed_by_id THEN
          RAISE EXCEPTION 'operator_proposals payload is immutable; withdraw and resubmit';
        END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER trg_operator_proposals_immutable BEFORE UPDATE ON operator_proposals
        FOR EACH ROW EXECUTE FUNCTION operator_proposal_payload_immutable();
    SQL

    change_table :sessions, bulk: true do |t|
      t.uuid :impersonating_merchant_id
      t.string :impersonation_case_ref
      t.datetime :impersonation_expires_at
    end
    add_foreign_key :sessions, :merchants, column: :impersonating_merchant_id

    change_table :settlement_lines, bulk: true do |t|
      t.datetime :reviewed_at
      t.uuid :reviewed_by_id
      t.text :review_note
    end
    add_foreign_key :settlement_lines, :operators, column: :reviewed_by_id
  end

  def down
    remove_foreign_key :settlement_lines, column: :reviewed_by_id
    change_table(:settlement_lines, bulk: true) { |t| t.remove :reviewed_at, :reviewed_by_id, :review_note }
    remove_foreign_key :sessions, column: :impersonating_merchant_id
    change_table(:sessions, bulk: true) { |t| t.remove :impersonating_merchant_id, :impersonation_case_ref, :impersonation_expires_at }
    drop_table :operator_proposals
    execute "DROP FUNCTION operator_proposal_payload_immutable()"
    drop_table :operators
  end
end
