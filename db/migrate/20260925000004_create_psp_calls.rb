class CreatePspCalls < ActiveRecord::Migration[8.1]
  # Evidence for the operator payment view (design decision 1). A timeout is a
  # row with no response: it is exactly the call that put a payment in `unknown`.
  def up
    create_table :psp_calls, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :psp_name, null: false
      t.string :operation, null: false        # e.g. "POST /charges", "GET /charges/:ref"
      t.string :psp_reference                 # ph_… or phr_… when the call is about one
      t.integer :http_status                  # NULL on timeout / unreachable
      t.string :outcome, null: false
      t.jsonb :request_redacted
      t.jsonb :response_redacted
      t.integer :duration_ms, null: false
      t.datetime :sent_at, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :psp_calls, "outcome IN ('ok', 'http_error', 'timeout', 'unreachable')", name: "chk_psp_calls_outcome"
    add_index :psp_calls, %i[psp_name psp_reference sent_at]
    execute <<~SQL
      CREATE TRIGGER trg_psp_calls_append_only
        BEFORE UPDATE OR DELETE ON psp_calls
        FOR EACH ROW EXECUTE FUNCTION append_only_guard('12 months');
    SQL
  end

  def down
    drop_table :psp_calls
  end
end
