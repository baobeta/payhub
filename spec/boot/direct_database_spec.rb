# frozen_string_literal: true

require "rails_helper"
require "open3"

# db: tasks never run through the transaction-mode PgBouncer (RUNBOOK
# "Connection pooling"). In child processes, as bin/rails runs them: the switch
# to MIGRATION_DATABASE_URL happens in db:load_config, which every db: task
# depends on, whether it runs from the command line or is invoked by another
# task (lib/tasks/direct_database.rake).
RSpec.describe "db: tasks and the pooled DATABASE_URL", :shells_out do # rubocop:disable RSpec/DescribeClass
  let(:db) { ActiveRecord::Base.connection_db_config.configuration_hash }
  let(:direct_url) do
    "postgres://#{ERB::Util.url_encode(db[:username])}:#{ERB::Util.url_encode(db[:password])}" \
      "@#{db[:host]}:#{db[:port]}/#{db[:database]}"
  end
  let(:pooled_url) { "#{direct_url}?advisory_locks=false" }
  # MIGRATION_DATABASE_URL nil: Open3 drops it, so the developer's shell cannot change the result.
  let(:env) { { "RAILS_ENV" => "test", "TEST_DATABASE" => db[:database], "MIGRATION_DATABASE_URL" => nil } }

  def rails(env, *args)
    Open3.capture3(env, "bin/rails", *args, chdir: Rails.root.to_s)
  end

  it "aborts a db: task on the pooled URL without MIGRATION_DATABASE_URL" do
    _out, err, status = rails(env.merge("DATABASE_URL" => pooled_url), "db:version")

    expect(status.success?).to be(false)
    expect(err).to include("DATABASE_URL is the pooled URL")
  end

  it "aborts a db: task invoked from inside another task, too" do
    _out, err, status = rails(env.merge("DATABASE_URL" => pooled_url),
                              "runner", 'Rails.application.load_tasks; Rake::Task["db:migrate"].invoke')

    expect(status.success?).to be(false)
    expect(err).to include("DATABASE_URL is the pooled URL")
  end

  it "uses MIGRATION_DATABASE_URL for db: tasks (an unreachable one is the one that fails)" do
    unreachable = "postgres://payhub:payhub@127.0.0.1:1/#{db[:database]}"
    _out, err, status = rails(env.merge("DATABASE_URL" => pooled_url, "MIGRATION_DATABASE_URL" => unreachable),
                              "db:version")

    expect(status.success?).to be(false)
    expect(err).to match(/127\.0\.0\.1.*port 1\b|port 1 failed/)
  end

  it "uses MIGRATION_DATABASE_URL for an invoked db: task" do
    script = 'Rails.application.load_tasks; Rake::Task["db:version"].invoke; ' \
             'puts "advisory_locks=#{ActiveRecord::Base.connection.advisory_locks_enabled?}"'
    out, err, status = rails(env.merge("DATABASE_URL" => pooled_url, "MIGRATION_DATABASE_URL" => direct_url),
                             "runner", script)

    expect(status.success?).to be(true), err
    expect(out).to include("Current version:").and include("advisory_locks=true")
  end

  it "leaves everything that is not a db: task on the pooled URL" do
    out, err, status = rails(env.merge("DATABASE_URL" => pooled_url, "MIGRATION_DATABASE_URL" => direct_url),
                             "runner", 'puts "advisory_locks=#{ActiveRecord::Base.connection.advisory_locks_enabled?}"')

    expect(status.success?).to be(true), err
    expect(out).to include("advisory_locks=false")
  end
end
