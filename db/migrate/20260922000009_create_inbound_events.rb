class CreateInboundEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :inbound_events, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :psp_name, null: false
      # The PSP's own event id.
      t.string :external_id, null: false
      t.string :event_type, null: false

      # Resolved to a payment at processing time. Deliberately NO foreign key:
      # a webhook can arrive before our worker has written the payment row,
      # and an FK would reject it — losing an event the PSP may never resend.
      t.string :psp_reference

      t.jsonb :payload, null: false
      # False => stored, alerted, 401 returned, never processed.
      t.boolean :signature_valid, null: false
      # Becomes payment_transitions.sort_key.
      t.datetime :psp_timestamp, precision: 6

      t.datetime :received_at, precision: 6, null: false
      t.datetime :processed_at, precision: 6
      t.string :error

      t.datetime :created_at, null: false
    end

    # Five identical webhooks => four RecordNotUnique => four no-ops with 200.
    add_index :inbound_events, [ :psp_name, :external_id ], unique: true, name: "idx_inbound_events_dedupe"
    add_index :inbound_events, [ :psp_name, :psp_reference ], name: "idx_inbound_events_by_ref"
    # Worklist for the processor: valid, not yet applied.
    add_index :inbound_events, :received_at, where: "processed_at IS NULL AND signature_valid",
              name: "idx_inbound_events_unprocessed"
  end
end
