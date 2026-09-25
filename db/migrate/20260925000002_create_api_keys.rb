class CreateApiKeys < ActiveRecord::Migration[8.1]
  # Many keys per merchant, so keys can be named, rolled with overlap and
  # revoked (design §2). merchants.api_key_digest stays until a later migration
  # drops it; this one only copies it.
  def up
    create_table :api_keys, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :merchant, type: :uuid, null: false, foreign_key: true
      t.boolean :livemode, null: false
      t.string :name, null: false
      t.string :note                        # "where is this key stored?"
      t.string :prefix, null: false         # sk_live_ / sk_test_
      t.string :last4                       # NULL for keys migrated from the digest column
      t.string :digest, null: false
      t.uuid :created_by_id                 # merchant_users arrives in phase 1; FK added then
      t.datetime :last_used_at
      t.datetime :expires_at                # set when rolled: the overlap window
      t.datetime :revoked_at                # set when revoked; rows are never deleted
      t.timestamps
    end
    add_index :api_keys, :digest, unique: true
    add_check_constraint :api_keys, "prefix IN ('sk_live_', 'sk_test_')", name: "chk_api_keys_prefix"

    execute <<~SQL
      INSERT INTO api_keys (merchant_id, livemode, name, prefix, digest, created_at, updated_at)
      SELECT id, true, 'Migrated key', 'sk_live_', api_key_digest, now(), now() FROM merchants;
    SQL
  end

  def down
    drop_table :api_keys
  end
end
