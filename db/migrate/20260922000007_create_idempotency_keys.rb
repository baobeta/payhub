class CreateIdempotencyKeys < ActiveRecord::Migration[7.2]
  def change
    create_table :idempotency_keys, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :merchant, type: :uuid, null: false, foreign_key: true, index: false

      t.string :key, null: false
      # SHA-256 of method + path + canonical body.
      # Same key + different fingerprint => 422 idempotency_error, never a replay.
      t.string :request_fingerprint, null: false

      # Both null while the request is in flight (=> 409 on a concurrent duplicate).
      t.integer :response_status
      t.jsonb :response_body

      t.datetime :locked_at
      t.datetime :expires_at, null: false

      t.timestamps
    end

    # THE referee. Claimed by INSERT and rescue RecordNotUnique,
    # never by SELECT-then-INSERT (DECISIONS #3).
    add_index :idempotency_keys, [ :merchant_id, :key ], unique: true, name: "idx_idempotency_merchant_key"
    add_index :idempotency_keys, :expires_at, name: "idx_idempotency_expiry"
  end
end
