# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# bin/generate-secrets (RUNBOOK "Secrets"): fresh values in the formats the app
# reads, and --append never overwrites a key.
RSpec.describe "bin/generate-secrets", :shells_out do # rubocop:disable RSpec/DescribeClass
  def run(*args)
    Open3.capture3(Rails.root.join("bin/generate-secrets").to_s, *args)
  end

  def parse(text)
    text.lines.filter_map { |line| line.chomp.split("=", 2) if line.match?(/\A[A-Z_]+=/) }.to_h
  end

  it "prints every secret in the format the app expects" do
    out, _err, status = run
    values = parse(out)

    expect(status.success?).to be(true)
    expect(values["SECRET_KEY_BASE"]).to match(/\A\h{128}\z/)
    %w[AR_ENCRYPTION_PRIMARY_KEY AR_ENCRYPTION_DETERMINISTIC_KEY AR_ENCRYPTION_KEY_DERIVATION_SALT].each do |key|
      expect(values[key]).to match(/\A[A-Za-z0-9]{32}\z/), key # what bin/rails db:encryption:init prints
    end
    expect(values["METRICS_TOKEN"]).to match(/\A\h{64}\z/)
    expect(values.values_at("APP_DB_PASSWORD", "OWNER_DB_PASSWORD")).to all(match(/\A\h{48}\z/)) # URL-safe
    expect(parse(run.first)).not_to eq(values)
  end

  it "--append adds only missing keys and never overwrites one" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "production.env")
      File.write(path, "WEB_PORT=3100\nMETRICS_TOKEN=keep-me\nSECRET_KEY_BASE=\n")
      _out, err, status = run("--append", path)
      values = parse(File.read(path))

      expect(status.success?).to be(true)
      expect(values).to include("WEB_PORT" => "3100", "METRICS_TOKEN" => "keep-me", "SECRET_KEY_BASE" => "")
      expect(values.keys).to include("AR_ENCRYPTION_PRIMARY_KEY", "APP_DB_PASSWORD", "OWNER_DB_PASSWORD")
      expect(File.read(path).scan(/^METRICS_TOKEN=/).size).to eq(1)
      expect(err).to include("SECRET_KEY_BASE is empty")
      expect(err).not_to include("keep-me")
    end
  end

  it "--append creates a new file with mode 600" do
    Dir.mktmpdir do |dir|
      fresh = File.join(dir, "new.env")
      run("--append", fresh)
      expect(File.stat(fresh).mode & 0o777).to eq(0o600)
    end
  end

  it "answers --help with exit 0, and refuses a directory or unknown arguments" do
    expect(run("--help").last.success?).to be(true)
    Dir.mktmpdir do |dir|
      _out, err, status = run("--append", dir)
      expect(status.success?).to be(false)
      expect(err).to include("is a directory")
    end
    expect(run("--bogus").last.success?).to be(false)
  end
end
