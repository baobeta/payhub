# frozen_string_literal: true

# Refuses a migration that would lock a busy table (README "Migrations",
# RUNBOOK "Safe migrations"). Loaded in every environment: production runs the
# migrations (RUN_MIGRATIONS=true), and the timeouts matter most there.

# Every migration up to here was already reviewed and has run; only newer ones are checked.
StrongMigrations.start_after = 20261021600001
# Checks follow PostgreSQL 16 in development and test; production uses the server's own version.
StrongMigrations.target_version = 16
# Session SETs on the migration connection only: a migration that waits on a lock
# queues writes behind it for at most 10s, then fails.
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour
# A new index is no use to the planner until the table's statistics are refreshed.
StrongMigrations.auto_analyze = true
# A concurrent build that failed leaves an INVALID index; a rerun add_index (same table, columns, options) drops it first.
StrongMigrations.remove_invalid_indexes = true
