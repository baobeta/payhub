class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def up
    # One guard for every append-only table after the ledger. The optional
    # argument is a retention interval: rows older than it may be deleted by the
    # purge job, and nothing else can ever be changed.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION append_only_guard() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND TG_NARGS > 0
           AND OLD.created_at < now() - TG_ARGV[0]::interval THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION '% is append-only (attempted %)', TG_TABLE_NAME, TG_OP;
      END
      $$ LANGUAGE plpgsql;
    SQL

    create_table :audit_events, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :actor_type                 # MerchantUser, Operator, or NULL for anonymous
      t.uuid :actor_id
      t.string :actor_label                # email at the time, kept even if the user is deleted
      t.uuid :merchant_id                  # tenant the event belongs to (server-verified)
      t.uuid :on_behalf_of_merchant_id     # set while an operator views as a merchant
      t.string :action, null: false        # e.g. authorization.denied, api_key.rolled
      t.string :target_type
      t.uuid :target_id
      t.string :result, null: false
      t.string :ip
      t.string :user_agent
      t.string :request_id
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_check_constraint :audit_events, "result IN ('success', 'denied', 'failure')", name: "chk_audit_events_result"
    add_index :audit_events, %i[merchant_id created_at]
    add_index :audit_events, %i[actor_type actor_id created_at]
    add_index :audit_events, %i[action created_at]

    execute <<~SQL
      CREATE TRIGGER trg_audit_events_append_only
        BEFORE UPDATE OR DELETE ON audit_events
        FOR EACH ROW EXECUTE FUNCTION append_only_guard('12 months');
    SQL
  end

  def down
    drop_table :audit_events
    execute "DROP FUNCTION IF EXISTS append_only_guard()"
  end
end
