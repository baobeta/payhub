# frozen_string_literal: true

require "rails_helper"

# Migrations and schema loads never go through the transaction-mode PgBouncer
# (RUNBOOK "Connection pooling"). The pooled DATABASE_URL carries
# advisory_locks=false; db: tasks switch to MIGRATION_DATABASE_URL
# (lib/tasks/direct_database.rake), and anything that would still migrate or
# load a schema with the pooled URL is refused
# (config/initializers/pooled_connection_guard.rb).
RSpec.describe "Migrations bypass the connection pool" do # rubocop:disable RSpec/DescribeClass
  let(:db_config) { ActiveRecord::Base.connection_db_config }
  let(:pooled_config) do
    ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary",
                                                         db_config.configuration_hash.merge(advisory_locks: "false"))
  end

  describe "the guard" do
    it "treats a config with advisory_locks=false as pooled, and the suite's own as direct" do
      expect(PooledConnectionGuard.pooled?(pooled_config)).to be(true)
      expect(PooledConnectionGuard.pooled?(db_config)).to be(false)
    end

    it "refuses to load the schema through the pool (maintain_test_schema!, db:schema:load)" do
      expect { ActiveRecord::Tasks::DatabaseTasks.load_schema(pooled_config) }
        .to raise_error(PooledConnectionGuard::PooledConnectionError, /load the schema through a transaction-mode pool/)
    end

    it "refuses to purge through the pool" do
      expect { ActiveRecord::Tasks::DatabaseTasks.purge(pooled_config) }
        .to raise_error(PooledConnectionGuard::PooledConnectionError, /purge the database/)
    end

    it "refuses to run migrations when the migration connection is pooled" do
      pool = ActiveRecord::Base.connection_pool
      allow(pool).to receive(:db_config).and_return(pooled_config)
      migrator = ActiveRecord::Migrator.new(:up, [], pool.schema_migration, pool.internal_metadata)

      expect { migrator.migrate }.to raise_error(PooledConnectionGuard::PooledConnectionError, /refusing to migrate/)
      expect { migrator.run }.to raise_error(PooledConnectionGuard::PooledConnectionError, /run a migration/)
    end

    it "refuses a single migration run on a pooled connection (a console, a runner)" do
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:advisory_locks_enabled?).and_return(false)
      allow(connection.pool).to receive(:db_config).and_return(pooled_config)
      migration = Class.new(ActiveRecord::Migration[8.1]) do
        def change
          create_table(:pooled_guard_spec)
        end
      end.new("pooled", 1).tap { |m| m.verbose = false }

      expect { migration.migrate(:up) }.to raise_error(PooledConnectionGuard::PooledConnectionError, /run a migration/)
      expect(connection.table_exists?(:pooled_guard_spec)).to be(false)
    end

    it "counts every false spelling Rails accepts for advisory_locks" do
      %w[false f 0 off FALSE].each do |value|
        config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", advisory_locks: value)
        expect(PooledConnectionGuard.pooled?(config)).to be(true), value
      end
    end

    it "lets migrations run on a direct connection" do
      pool = ActiveRecord::Base.connection_pool
      migrator = ActiveRecord::Migrator.new(:up, [], pool.schema_migration, pool.internal_metadata)

      expect { migrator.migrate }.not_to raise_error
    end
  end
end
