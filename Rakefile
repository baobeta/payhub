# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

# db:schema:dump shells out to `pg_dump`; bin/pg_dump picks a client that
# matches the Postgres 16 server (see that file).
ENV["PATH"] = "#{__dir__}/bin:#{ENV['PATH']}"

# db: tasks (migrate, prepare, schema:load, seed, ...) connect to Postgres
# directly, never through the transaction-mode PgBouncer that DATABASE_URL
# points at: strong_migrations' lock_timeout / statement_timeout are session
# SETs that would stay on a pooled server connection and leak into app
# traffic, and Rails' migration lock is a session advisory lock the pool does
# not hold. MIGRATION_DATABASE_URL is that direct URL (Compose sets it on web
# and worker). Production's migration container gets the owner's direct URL
# as DATABASE_URL instead. RUNBOOK "Connection pooling".
if Rake.application.top_level_tasks.any? { |task| task.start_with?("db:") }
  if ENV["MIGRATION_DATABASE_URL"].to_s != ""
    ENV["DATABASE_URL"] = ENV["MIGRATION_DATABASE_URL"]
  elsif ENV["DATABASE_URL"].to_s.include?("advisory_locks=false")
    abort "#{Rake.application.top_level_tasks.join(' ')}: DATABASE_URL is the pooled URL " \
          "(advisory_locks=false); set MIGRATION_DATABASE_URL to Postgres itself " \
          "(RUNBOOK \"Connection pooling\")"
  end
end

require_relative "config/application"

Rails.application.load_tasks
