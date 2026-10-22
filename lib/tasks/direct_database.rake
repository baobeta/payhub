# frozen_string_literal: true

# Every db: task (migrate, prepare, schema:load, seed, ...) depends on
# db:load_config, so this runs first for `bin/rails db:x` and for
# Rake::Task["db:x"].invoke from inside another task alike: when
# MIGRATION_DATABASE_URL (Postgres itself, no pooler) is set, it replaces the
# pooled DATABASE_URL and Active Record reconnects with it. Compose sets it on
# web and worker. Production's migration container gets the owner's direct URL
# as DATABASE_URL instead. Without MIGRATION_DATABASE_URL, a db: task on the
# pooled URL aborts here; config/initializers/pooled_connection_guard.rb covers
# the routes that are not db: tasks. RUNBOOK "Connection pooling".
#
# The switch is per process: `bin/rails db:migrate chaos:run` runs chaos:run on
# the direct URL too, so run app tasks in their own command.
namespace :db do
  task direct_connection: :environment do
    direct = ENV["MIGRATION_DATABASE_URL"].presence
    if direct.nil?
      next unless PooledConnectionGuard.pooled?(ActiveRecord::Base.connection_db_config)

      abort "#{Rake.application.top_level_tasks.join(' ')}: DATABASE_URL is the pooled URL " \
            "(advisory_locks=false); set MIGRATION_DATABASE_URL to Postgres itself (RUNBOOK \"Connection pooling\")"
    end
    next if ENV["DATABASE_URL"] == direct

    ENV["DATABASE_URL"] = direct
    ActiveRecord::Base.configurations = Rails.application.config.database_configuration
    ActiveRecord::Base.establish_connection
  end
end

Rake::Task["db:load_config"].enhance(["db:direct_connection"])
