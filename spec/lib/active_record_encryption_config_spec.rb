# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Active Record encryption" do # rubocop:disable RSpec/DescribeClass
  it "is configured, so encrypted columns can be read and written" do
    config = ActiveRecord::Encryption.config
    expect([config.primary_key, config.deterministic_key, config.key_derivation_salt]).to all(be_present)
  end
end
