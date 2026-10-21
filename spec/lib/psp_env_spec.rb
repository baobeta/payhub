require "rails_helper"

RSpec.describe PspEnv do
  it "PR-2: outside production a missing variable falls back to the simulator default" do
    stub_const("ENV", ENV.to_h.except("PAYHUB_TEST_MISSING_VAR"))
    expect(described_class.fetch("PAYHUB_TEST_MISSING_VAR", "np_test_key")).to eq("np_test_key")
  end

  it "PR-2: outside production an empty variable also falls back to the simulator default" do
    stub_const("ENV", ENV.to_h.merge("PAYHUB_TEST_VAR" => ""))
    expect(described_class.fetch("PAYHUB_TEST_VAR", "np_test_key")).to eq("np_test_key")
  end

  context "when in production" do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it "PR-2: a missing variable raises and names it" do
      stub_const("ENV", ENV.to_h.except("PAYHUB_TEST_MISSING_VAR"))
      expect { described_class.fetch("PAYHUB_TEST_MISSING_VAR", "np_test_key") }
        .to raise_error(PspEnv::Missing, /PAYHUB_TEST_MISSING_VAR/)
    end

    it "PR-2: an empty variable raises" do
      stub_const("ENV", ENV.to_h.merge("PAYHUB_TEST_VAR" => ""))
      expect { described_class.fetch("PAYHUB_TEST_VAR", "np_test_key") }.to raise_error(PspEnv::Missing, /PAYHUB_TEST_VAR/)
    end

    it "PR-2: a simulator default value is refused even when set" do
      stub_const("ENV", ENV.to_h.merge("PAYHUB_TEST_VAR" => "np_test_key"))
      expect { described_class.fetch("PAYHUB_TEST_VAR", "np_test_key") }.to raise_error(PspEnv::Missing, /test value/)
    end

    it "PR-2: a real value is returned" do
      stub_const("ENV", ENV.to_h.merge("PAYHUB_TEST_VAR" => "np_live_key"))
      expect(described_class.fetch("PAYHUB_TEST_VAR", "np_test_key")).to eq("np_live_key")
    end
  end

  describe ".verify_production!" do
    let(:live_env) do
      {
        "NORDPAY_URL" => "https://nordpay.example", "NORDPAY_API_KEY" => "np_live",
        "NORDPAY_WEBHOOK_SECRET" => "np_whsec_live",
        "KIRIPAY_URL" => "https://kiripay.example", "KIRIPAY_API_KEY" => "kp_live",
        "KIRIPAY_WEBHOOK_SECRET" => "kp_whsec_live"
      }
    end
    let(:base_env) { ENV.to_h.except("NORDPAY_WEBHOOK_SECRETS", "KIRIPAY_WEBHOOK_SECRETS").merge(live_env) }

    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it "PR-2: passes when every PSP variable has a real value" do
      stub_const("ENV", base_env)
      expect { described_class.verify_production! }.not_to raise_error
    end

    it "PR-2: fails when a PSP variable is missing, naming it" do
      stub_const("ENV", base_env.except("KIRIPAY_API_KEY"))
      expect { described_class.verify_production! }.to raise_error(PspEnv::Missing, /KIRIPAY_API_KEY/)
    end

    it "PR-2: fails when a webhook secret list holds no secret, naming it" do
      stub_const("ENV", base_env.merge("NORDPAY_WEBHOOK_SECRETS" => " , "))
      expect { described_class.verify_production! }.to raise_error(PspEnv::Missing, /NORDPAY_WEBHOOK_SECRETS/)
    end

    it "PR-2: fails when a webhook secret list holds the simulator's secret, naming it" do
      stub_const("ENV", base_env.merge("NORDPAY_WEBHOOK_SECRETS" => "np_whsec_test"))
      expect { described_class.verify_production! }.to raise_error(PspEnv::Missing, /NORDPAY_WEBHOOK_SECRETS/)
    end

    it "PR-2: does nothing outside production" do
      allow(Rails.env).to receive(:production?).and_return(false)
      stub_const("ENV", base_env.except("KIRIPAY_API_KEY"))
      expect { described_class.verify_production! }.not_to raise_error
    end
  end
end
