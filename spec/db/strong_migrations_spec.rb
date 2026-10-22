# frozen_string_literal: true

require "rails_helper"

# strong_migrations stops a migration that would lock a busy table before it
# sends any SQL (README "Migrations", RUNBOOK "Safe migrations").
RSpec.describe "strong_migrations" do # rubocop:disable RSpec/DescribeClass
  def migration(version)
    Class.new(ActiveRecord::Migration[8.1]) do
      def change
        add_index :merchants, :created_at, name: "idx_strong_migrations_spec"
      end
    end.new("unsafe_index", version).tap { |m| m.verbose = false }
  end

  it "PR-12: refuses a new migration that adds an index without CONCURRENTLY" do
    expect { migration(StrongMigrations.start_after + 1).migrate(:up) }
      .to raise_error(StrongMigrations::UnsafeMigration, /Adding an index non-concurrently blocks writes/)
    expect(ActiveRecord::Base.connection.index_name_exists?(:merchants, "idx_strong_migrations_spec")).to be(false)
  end

  it "PR-12: leaves migrations up to start_after unchecked (they have already run)" do
    connection = ActiveRecord::Base.connection

    # The index and the session timeouts both roll back with the example.
    expect { migration(StrongMigrations.start_after).migrate(:up) }.not_to raise_error
    expect(connection.index_name_exists?(:merchants, "idx_strong_migrations_spec")).to be(true)
    expect(connection.select_value("SHOW lock_timeout")).to eq("10s")
  end
end
