class CreateDemoEpochsAndChaosRuns < ActiveRecord::Migration[8.1]
  # "Reset" cannot delete: payments and ledger entries are append-only
  # (DECISIONS #5). A reset starts a new epoch; the demo shows rows created
  # since the current one began.
  def up
    create_table :demo_epochs, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.datetime :started_at, null: false
      t.string :started_by_ip
    end
    add_index :demo_epochs, :started_at

    create_table :demo_chaos_runs, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :state, null: false, default: "queued"
      t.integer :payments, null: false
      t.jsonb :result
      t.string :error
      t.string :started_by_ip
      t.datetime :finished_at
      t.timestamps
    end
    add_check_constraint :demo_chaos_runs, "state IN ('queued', 'running', 'passed', 'failed', 'errored')", name: "chk_demo_chaos_runs_state"
    add_check_constraint :demo_chaos_runs, "payments BETWEEN 1 AND 20", name: "chk_demo_chaos_runs_size"
    # One chaos run at a time, system-wide (design §4 abuse limits).
    add_index :demo_chaos_runs, :state, unique: true, where: "state IN ('queued', 'running')", name: "idx_demo_chaos_runs_one_active"
  end

  def down
    drop_table :demo_chaos_runs
    drop_table :demo_epochs
  end
end
