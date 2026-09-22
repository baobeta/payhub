class CreatePaymentTransitions < ActiveRecord::Migration[7.2]
  def change
    create_table :payment_transitions, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :payment, type: :uuid, null: false, foreign_key: true, index: false

      t.string :from_state # null for the initial pending row
      t.string :to_state, null: false

      # The PSP's own event timestamp, NOT our arrival time. This is the
      # ordering key that makes out-of-order webhooks safe (DECISIONS #4).
      t.datetime :sort_key, precision: 6, null: false
      t.boolean :most_recent, null: false, default: false

      # api | worker | webhook | sweeper — who caused this transition.
      t.string :source, null: false
      t.jsonb :metadata, null: false, default: {}

      # Arrival time. (created_at - sort_key) is the webhook lag we log.
      t.datetime :created_at, precision: 6, null: false
    end

    # Exactly one current row per payment, enforced by Postgres, not Ruby.
    add_index :payment_transitions, :payment_id, unique: true,
              where: "most_recent", name: "idx_transitions_most_recent"

    # Transition history in PSP-time order for GET /v1/payments/:id.
    add_index :payment_transitions, [ :payment_id, :sort_key ], name: "idx_transitions_history"
  end
end
