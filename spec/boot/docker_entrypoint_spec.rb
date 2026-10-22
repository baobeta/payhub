# frozen_string_literal: true

require "rails_helper"
require "open3"

# bin/docker-entrypoint, run directly with bash. The refusal happens before
# db:prepare; DATABASE_URL points nowhere so a regression fails instead of
# migrating a real database.
RSpec.describe "bin/docker-entrypoint", :shells_out do # rubocop:disable RSpec/DescribeClass
  let(:env) do
    { "DATABASE_URL" => "postgres://nobody@127.0.0.1:1/nowhere", "PROMETHEUS_MULTIPROC_DIR" => nil,
      "RUN_MIGRATIONS" => nil, "ALLOW_MIGRATE_AND_SERVE" => nil }
  end

  def entrypoint(*command, **vars)
    Open3.capture3(env.merge(vars), "bash", Rails.root.join("bin/docker-entrypoint").to_s, *command,
                   chdir: Rails.root.to_s)
  end

  [
    %w[bundle exec puma -C config/puma.rb],
    %w[bundle exec sidekiq],
    %w[bin/rails server -b 0.0.0.0],
    ["sh", "-c", "exec bin/rails server -b 0.0.0.0"]
  ].each do |command|
    it "PR-10: refuses RUN_MIGRATIONS=true with the server command `#{command.join(' ')}`" do
      _out, err, status = entrypoint(*command, "RUN_MIGRATIONS" => "true")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("refusing RUN_MIGRATIONS=true with a server command")
    end
  end

  it "PR-10: without RUN_MIGRATIONS runs the command as given" do
    out, _err, status = entrypoint("echo", "puma started")
    expect(status.exitstatus).to eq(0)
    expect(out).to eq("puma started\n")
  end
end
