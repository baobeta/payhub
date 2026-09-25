class CreateMerchantUsersAndSessions < ActiveRecord::Migration[8.1]
  def up
    create_table :merchant_users, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :merchant, type: :uuid, null: false, foreign_key: true
      t.string :email, null: false
      t.string :name
      t.string :password_digest              # NULL until the invitation is accepted
      t.string :role, null: false
      t.text :otp_secret                     # encrypted by Active Record
      t.datetime :otp_enabled_at
      t.bigint :otp_last_used_step           # TOTP replay guard
      t.integer :failed_attempts, null: false, default: 0
      t.datetime :locked_until
      t.uuid :invited_by_id
      t.string :invitation_digest
      t.datetime :invitation_expires_at
      t.datetime :accepted_at
      t.datetime :disabled_at
      t.timestamps
    end
    add_index :merchant_users, "lower(email)", unique: true, name: "idx_merchant_users_email"
    add_index :merchant_users, :invitation_digest, unique: true, where: "invitation_digest IS NOT NULL"
    add_index :merchant_users, :merchant_id, unique: true, where: "role = 'owner' AND disabled_at IS NULL",
                                             name: "idx_merchant_users_one_owner"
    add_check_constraint :merchant_users, "role IN ('owner', 'admin', 'developer', 'support', 'viewer')",
                         name: "chk_merchant_users_role"
    add_foreign_key :merchant_users, :merchant_users, column: :invited_by_id
    add_foreign_key :api_keys, :merchant_users, column: :created_by_id

    # Polymorphic so operators (phase 2) share it. Never deleted: revoked_at
    # ends a session, and the rows are evidence for the security history.
    create_table :sessions, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :principal_type, null: false
      t.uuid :principal_id, null: false
      t.string :ip
      t.string :user_agent
      t.boolean :livemode, null: false, default: true
      t.datetime :last_active_at, null: false
      t.datetime :stepped_up_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :sessions, %i[principal_type principal_id created_at]
    add_check_constraint :sessions, "principal_type IN ('MerchantUser', 'Operator')", name: "chk_sessions_principal_type"

    create_table :recovery_codes, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :principal_type, null: false
      t.uuid :principal_id, null: false
      t.string :code_digest, null: false
      t.datetime :used_at
      t.datetime :created_at, null: false
    end
    add_index :recovery_codes, %i[principal_type principal_id]
    add_index :recovery_codes, :code_digest, unique: true
  end

  def down
    drop_table :recovery_codes
    drop_table :sessions
    remove_foreign_key :api_keys, column: :created_by_id
    drop_table :merchant_users
  end
end
