# frozen_string_literal: true

require "rails_helper"
require "open3"

# The test env only uses a test database, connected to Postgres directly
# (lib/test_database.rb, config/application.rb,
# config/initializers/test_database_guard.rb). Inside Compose, web and worker
# carry a pooled DATABASE_URL and a direct MIGRATION_DATABASE_URL, both to
# payhub_development; a test process there must ignore them. Here they name a
# database that does not exist, so a regression fails on "does not exist"
# instead of running on a real one.
RSpec.describe "The test database", :shells_out do # rubocop:disable RSpec/DescribeClass
  let(:db) { ActiveRecord::Base.connection_db_config.configuration_hash }
  let(:server) do
    "postgres://#{ERB::Util.url_encode(db[:username])}:#{ERB::Util.url_encode(db[:password])}@#{db[:host]}:#{db[:port]}"
  end
  let(:absent) { "payhub_dev_absent_spec" }
  # Compose's web/worker variables, pointed at this suite's server.
  let(:compose_urls) do
    { "DATABASE_URL" => "#{server}/#{absent}?advisory_locks=false&prepared_statements=false",
      "MIGRATION_DATABASE_URL" => "#{server}/#{absent}" }
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
    expect(err).to include(%([test_database] ignoring DATABASE_URL: "#{absent}" is not a test database))
      .and include(%([test_database] ignoring MIGRATION_DATABASE_URL: "#{absent}"))
    expect(err).not_to include("postgres://") # the database name only, never the credentials
  end

  it "keeps a DATABASE_URL that names no database (Rails takes the database from config/database.yml)" do
    out, err, status = rails(env.merge("DATABASE_URL" => "#{server}/", "MIGRATION_DATABASE_URL" => nil),
                             "runner", report)

    expect(status.success?).to be(true), err
    expect(out).to include(expected)
    expect(err).not_to include("[test_database]")
  end

  it "runs db: tasks against the test database too, not MIGRATION_DATABASE_URL's" do
    script = "Rails.application.load_tasks; Rake::Task['db:version'].invoke; #{report}"
    out, err, status = rails(env.merge(compose_urls), "runner", script)

    expect(status.success?).to be(true), err
    expect(out).to include("Current version:").and include(expected)
  end

  it "applies to bin/rails -e test as well as RAILS_ENV=test" do
    out, err, status = rails(env.merge(compose_urls, "RAILS_ENV" => nil, "RACK_ENV" => nil), "runner", "-e", "test",
                             report)

    expect(status.success?).to be(true), err
    expect(out).to include(expected)
  end

  it "refuses to boot the test env on a database that is not a test database" do
    _out, err, status = rails(env.merge("TEST_DATABASE" => absent, "DATABASE_URL" => nil,
                                        "MIGRATION_DATABASE_URL" => nil), "runner", "puts :booted")

    expect(status.success?).to be(false)
    expect(err).to include(%(refusing to use "#{absent}" as the test database))
  end

  it "runs rspec in the test env even when the caller's RAILS_ENV is development (the web container's)" do
    spec = Rails.root.join("tmp", "test_database_probe_#{Process.pid}_spec.rb")
    spec.write(<<~RUBY)
      require "rails_helper"
      RSpec.describe "probe" do # rubocop:disable RSpec/DescribeClass
        it("reports") { #{report} }
      end
    RUBY
    out, err, status = Open3.capture3(env.merge(compose_urls, "RAILS_ENV" => "development", "RACK_ENV" => nil,
                                                "COVERAGE" => "false"),
                                      "bundle", "exec", "rspec", spec.to_s, chdir: Rails.root.to_s)

    expect(status.success?).to be(true), out + err
    expect(out).to include(expected).and include("1 example, 0 failures")
  ensure
    spec&.delete if spec&.exist?
  end

  it "prepares a test database with bin/rails db:test:prepare from the development env, despite Compose's URLs" do
    scratch = "#{db[:database]}_prep"
    out, err, status = rails(env.merge(compose_urls, "RAILS_ENV" => nil, "RACK_ENV" => nil, "TEST_DATABASE" => scratch),
                             "db:test:prepare")

    expect(status.success?).to be(true), out + err
    tables = rails(env.merge("TEST_DATABASE" => scratch, "DATABASE_URL" => nil, "MIGRATION_DATABASE_URL" => nil),
                   "runner", 'puts "tables=#{ActiveRecord::Base.connection.tables.size}"').first
    expect(tables[/tables=(\d+)/, 1].to_i).to be > 10
  ensure
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: "postgres")
      .tap { |pg| pg.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(scratch)}") }.close
  end

  describe "the guard on db:test:* tasks (run from any env)" do
    # A database that does not exist: should the guard ever let it through,
    # the task fails on the missing database instead of touching one.
    let(:foreign) do
      ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", db.merge(database: "payhub_guard_spec"))
    end

    it "refuses to purge, load into or truncate a test config that names another database" do
      tasks = ActiveRecord::Tasks::DatabaseTasks
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

    it "reads the database from a URL, nil when it names none" do
      expect(described_class.database_in("postgres://u:p@db:5432/payhub_development?advisory_locks=false"))
        .to eq("payhub_development")
      expect(described_class.database_in("postgres://u:p@db:5432")).to be_nil
      expect(described_class.database_in("postgres://u:p@db:5432/")).to be_nil
    end
  end
end
