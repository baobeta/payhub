# typed: strict
# frozen_string_literal: true

require "uri"

# The test environment only ever touches a test database, connected to
# Postgres directly (RUNBOOK "Connection pooling"). Specs truncate tables and
# use session SETs (session_replication_role, ROLE) that must not leak through
# PgBouncer, so a test database is reached by host/port, never by the pool.
module TestDatabase
  extend T::Sig

  class NotATestDatabaseError < StandardError; end

  # payhub_test, payhub_test_<lane> (TEST_DATABASE per worktree), payhub_e2e
  # (Playwright).
  NAME = /_(test|e2e)(_|\z)/
  URL_VARIABLES = T.let(%w[DATABASE_URL MIGRATION_DATABASE_URL].freeze, T::Array[String])

  sig { params(database: T.nilable(String)).returns(T::Boolean) }
  def self.name?(database)
    NAME.match?(database.to_s)
  end

  # Called in the test env before Active Record reads its configuration.
  # Compose sets DATABASE_URL (pooled) and MIGRATION_DATABASE_URL (direct) on
  # web and worker, both to payhub_development; a test process there would
  # otherwise run on, and truncate, the dev database. A URL that names a test
  # database is kept (spec/boot/direct_database_spec.rb sets them).
  sig { void }
  def self.drop_foreign_urls!
    URL_VARIABLES.each do |var|
      url = ENV.fetch(var, nil)
      ENV.delete(var) unless url.nil? || name?(database_in(url))
    end
  end

  sig { params(database: T.nilable(String)).void }
  def self.refuse_unless_test!(database)
    return if name?(database)

    raise NotATestDatabaseError,
          "refusing to use #{database.inspect} as the test database: its name must contain _test or _e2e " \
          "(payhub_test, payhub_test_<lane>, payhub_e2e); check TEST_DATABASE and DATABASE_URL"
  end

  sig { params(url: String).returns(T.nilable(String)) }
  def self.database_in(url)
    URI.parse(url).path&.delete_prefix("/")
  rescue URI::InvalidURIError
    nil
  end
end
