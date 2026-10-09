# frozen_string_literal: true

require "rails_helper"

RSpec.describe StateMachineExport do
  it "includes the deliberate unknown -> failed edge" do
    expect(described_class.typescript).to include('["unknown","failed"]')
  end

  it "omits the unknown -> canceled edge DECISIONS #10 refuses" do
    expect(described_class.typescript).not_to include('["unknown","canceled"]')
  end
end
