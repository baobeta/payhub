# frozen_string_literal: true

# Refuses a migration that would lock a busy table (README "Migrations",
# RUNBOOK "Safe migrations"). Loaded in every environment: production runs the
# migrations (RUN_MIGRATIONS=true), and the timeouts matter most there.

# Every migration up to here was already reviewed and has run; only newer ones are checked.
StrongMigrations.start_after = 20261021600001
# Checks follow PostgreSQL 16 in development and test; production uses the server's own version.
StrongMigrations.target_version = 16
# Session SETs on the migration connection only: a migration that waits on a lock
# gives up after 10s instead of queueing every write behind it.
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour
