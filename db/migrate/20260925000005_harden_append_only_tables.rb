class HardenAppendOnlyTables < ActiveRecord::Migration[8.1]
  # Two holes in append_only_guard's row triggers:
  # - TRUNCATE fires no row trigger, so it could wipe the table silently;
  # - the retention window reads created_at, which the application wrote, so
  #   a row inserted "13 months old" could be deleted at once.
  # The database now owns created_at, and TRUNCATE goes through the guard,
  # which raises for any operation other than an expired DELETE.
  TABLES = %w[audit_events psp_calls].freeze

  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION stamp_created_at() RETURNS trigger AS $$
      BEGIN
        NEW.created_at := now();
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql;
    SQL

    TABLES.each do |table|
      execute <<~SQL
        CREATE TRIGGER trg_#{table}_stamp_created_at
          BEFORE INSERT ON #{table}
          FOR EACH ROW EXECUTE FUNCTION stamp_created_at();
        CREATE TRIGGER trg_#{table}_no_truncate
          BEFORE TRUNCATE ON #{table}
          FOR EACH STATEMENT EXECUTE FUNCTION append_only_guard();
      SQL
    end
  end

  def down
    TABLES.each do |table|
      execute "DROP TRIGGER trg_#{table}_no_truncate ON #{table}"
      execute "DROP TRIGGER trg_#{table}_stamp_created_at ON #{table}"
    end
    execute "DROP FUNCTION stamp_created_at()"
  end
end
