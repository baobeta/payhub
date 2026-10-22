# typed: false
# frozen_string_literal: true

# Migrations and schema loads never run through the transaction-mode PgBouncer
# (RUNBOOK "Connection pooling"): strong_migrations' lock_timeout and
# statement_timeout are session SETs that would stay on a pooled server
# connection, and Rails' migration lock is a session advisory lock the pool
# does not hold. The pooled DATABASE_URL carries advisory_locks=false, so a
# connection without advisory locks is taken to be pooled.
#
# This covers every route to a migration or a schema load, not only rake:
# bin/rails db:*, Rake::Task["db:..."].invoke, maintain_test_schema!, the
# development error page's "Run pending migrations" button, a MigrationContext
# built by hand, a single migration run in a console (Migration#migrate). db:
# tasks normally never get here with the pooled URL: they switch to
# MIGRATION_DATABASE_URL first, or abort (lib/tasks/direct_database.rake).
module PooledConnectionGuard
  class PooledConnectionError < StandardError; end

  MESSAGE = "refusing to %s through a transaction-mode pool (advisory_locks=false in DATABASE_URL): " \
            "set MIGRATION_DATABASE_URL to Postgres itself and run it as a db: task " \
            "(RUNBOOK \"Connection pooling\")"

  # The same cast Rails applies to advisory_locks, so "false", "f", "0" and
  # "off" all count.
  def self.pooled?(db_config)
    ActiveModel::Type::Boolean.new.cast(db_config.configuration_hash.fetch(:advisory_locks, true)) == false
  end

  def self.refuse!(action, db_config)
    raise PooledConnectionError, format(MESSAGE, action) if pooled?(db_config)
  end

  # Every migration, whoever runs it, ends here with its connection.
  module Migration
    def exec_migration(conn, direction)
      PooledConnectionGuard.refuse!("run a migration", conn.pool.db_config) unless conn.advisory_locks_enabled?
      super
    end
  end

  module Migrator
    def run
      PooledConnectionGuard.refuse!("run a migration", connection.pool.db_config)
      super
    end

    def migrate
      PooledConnectionGuard.refuse!("migrate", connection.pool.db_config)
      super
    end
  end

  module DatabaseTasks
    def load_schema(db_config, *)
      PooledConnectionGuard.refuse!("load the schema", db_config)
      super
    end

    def purge(configuration)
      PooledConnectionGuard.refuse!("purge the database", resolve_configuration(configuration))
      super
    end
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Migration.prepend(PooledConnectionGuard::Migration)
  ActiveRecord::Migrator.prepend(PooledConnectionGuard::Migrator)
  ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(PooledConnectionGuard::DatabaseTasks)
end
