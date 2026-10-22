# frozen_string_literal: true

require "rails_helper"
require "open3"

# The test env only uses a test database, connected to Postgres directly
# (lib/test_database.rb, config/application.rb,
# config/initializers/test_database_guard.rb). Inside Compose, web and worker
# carry a pooled DATABASE_URL and a direct MIGRATION_DATABASE_URL, both to
# payhub_development; a test process there must ignore them.
RSpec.describe "The test database", :shells_out do # rubocop:disable RSpec/DescribeClass
  let(:db) { ActiveRecord::Base.connection_db_config.configuration_hash }
  let(:server) do
    "postgres://#{ERB::Util.url_encode(db[:username])}:#{ERB::Util.url_encode(db[:password])}@#{db[:host]}:#{db[:port]}"
  end
  # Compose's web/worker variables, pointed at this suite's server.
  let(:compose_urls) do
    { "DATABASE_URL" => "#{server}/payhub_development?advisory_locks=false&prepared_statements=false",
      "MIGRATION_DATABASE_URL" => "#{server}/payhub_development" }
  end
  let(:env) { { "RAILS_ENV" => "test", "TEST_DATABASE" => db[:database] } }
  let(:expected) { "db=#{[db[:database], db[:host], db[:port], true].join(",")}" }
  let(:report) do
    'c = ActiveRecord::Base.connection_db_config.configuration_hash; ' \
      'puts "db=" + [c[:database], c[:host], c[:port], ActiveRecord::Base.connection.advisory_locks_enabled?].join(",")'
  end

  def rails(env, *args)
    Open3.capture3(env, "bin/rails", *args, chdir: Rails.root.to_s)
  end

  it "ignores Compose's dev DATABASE_URL and MIGRATION_DATABASE_URL and connects to the test database directly" do
    out, err, status = rails(env.merge(compose_urls), "runner", report)

    expect(status.success?).to be(true), err
    expect(out).to include(expected)
  end

  it "runs db: tasks against the test database too, not MIGRATION_DATABASE_URL's" do
    script = "Rails.application.load_tasks; Rake::Task['db:version'].invoke; #{report}"
    out, err, status = rails(env.merge(compose_urls), "runner", script)

    expect(status.success?).to be(true), err
    expect(out).to include("Current version:").and include(expected)
  end

  it "applies to bin/rails -e test as well as RAILS_ENV=test" do
    out, err, status = rails(env.merge(compose_urls, "RAILS_ENV" => nil), "runner", "-e", "test", report)

    expect(status.success?).to be(true), err
    expect(out).to include(expected)
  end

  it "refuses to boot the test env on a database that is not a test database" do
    _out, err, status = rails(env.merge("TEST_DATABASE" => "payhub_development", "DATABASE_URL" => nil,
                                        "MIGRATION_DATABASE_URL" => nil), "runner", "puts :booted")

    expect(status.success?).to be(false)
    expect(err).to include('refusing to use "payhub_development" as the test database')
  end

  describe "the guard on db:test:* tasks (run from any env)" do
    # A database that does not exist: should the guard ever let it through,
    # the task fails on the missing database instead of touching one.
    let(:foreign) do
      ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", db.merge(database: "payhub_guard_spec"))
    end
    let(:tasks) { ActiveRecord::Tasks::DatabaseTasks }

    it "refuses to purge, load into or truncate a test config that names another database" do
      expect { tasks.purge(foreign) }.to raise_error(TestDatabase::NotATestDatabaseError, /payhub_guard_spec/)
      expect { tasks.load_schema(foreign) }.to raise_error(TestDatabase::NotATestDatabaseError)
      expect { tasks.send(:truncate_tables, foreign) }.to raise_error(TestDatabase::NotATestDatabaseError)
    end
  end

  describe TestDatabase do
    it "accepts payhub_test, per-lane test databases and Playwright's" do
      expect(%w[payhub_test payhub_test_ctdb payhub_e2e].map { |name| described_class.name?(name) }).to all(be(true))
    end

    it "rejects every other name" do
      expect([nil, "", "payhub_development", "payhub_production", "payhub_testing", "latest"]
               .map { |name| described_class.name?(name) }).to all(be(false))
    end

    it "reads the database from a URL" do
      expect(described_class.database_in("postgres://u:p@db:5432/payhub_development?advisory_locks=false"))
        .to eq("payhub_development")
    end
  end
end
