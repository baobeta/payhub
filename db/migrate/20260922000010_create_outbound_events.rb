class CreateOutboundEvents < ActiveRecord::Migration[7.2]
  def change
    # Transactional outbox: written in the same transaction as the state change
    # that caused it, delivered later by a sweeper with backoff.
    create_table :outbound_events, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :merchant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :payment, type: :uuid, foreign_key: true

      t.string :event_type, null: false
      t.jsonb :payload, null: false

      t.string :state, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at, precision: 6, null: false
      t.string :last_error
      t.datetime :delivered_at, precision: 6

      t.timestamps
    end

    add_check_constraint :outbound_events, "state IN ('pending', 'delivered', 'dead')", name: "chk_outbound_events_state"

    # Delivery sweeper: WHERE state = 'pending' AND next_attempt_at <= now().
    add_index :outbound_events, [ :state, :next_attempt_at ], name: "idx_outbound_events_sweeper"
    # GET /v1/events
    add_index :outbound_events, [ :merchant_id, :created_at ], order: { created_at: :desc },
              name: "idx_outbound_events_list"

    # One row per delivery try, so GET /v1/events shows the history and
    # webhook_deliveries{attempt=N} can be counted.
    create_table :outbound_delivery_attempts, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :outbound_event, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :attempt_number, null: false
      t.integer :response_status
      t.string :error
      t.integer :duration_ms
      t.datetime :created_at, precision: 6, null: false
    end

    add_index :outbound_delivery_attempts, [ :outbound_event_id, :attempt_number ], unique: true,
              name: "idx_delivery_attempts_unique"
  end
end
