require "rails_helper"

RSpec.describe PspEnv do
  it "PR-2: outside production a missing variable falls back to the simulator default" do
    expect(described_class.fetch("PAYHUB_TEST_MISSING_VAR", "np_test_key")).to eq("np_test_key")
  end

  it "PR-2: in production a missing variable raises and names it" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect { described_class.fetch("PAYHUB_TEST_MISSING_VAR", "np_test_key") }
      .to raise_error(PspEnv::Missing, /PAYHUB_TEST_MISSING_VAR/)
  end

  it "PR-2: in production a simulator default value is refused even when set" do
    allow(Rails.env).to receive(:production?).and_return(true)
    stub_const("ENV", ENV.to_h.merge("PAYHUB_TEST_VAR" => "np_test_key"))
    expect { described_class.fetch("PAYHUB_TEST_VAR", "np_test_key") }.to raise_error(PspEnv::Missing, /test value/)
  end
end
