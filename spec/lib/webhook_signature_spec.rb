require "rails_helper"

RSpec.describe WebhookSignature do
  let(:body) { '{"id":"evt_1"}' }
  let(:now) { Time.current }

  def hmac(secret, data) = OpenSSL::HMAC.hexdigest("SHA256", secret, data)

  describe ".header / .verify_timestamped!" do
    it "signs once per active secret, and verifies with either during a rotation" do
      header = described_class.header(body, secrets: %w[new old], at: now.to_i)

      expect(header.scan("v1=").size).to eq(2)
      expect { described_class.verify_timestamped!(body, header, secrets: ["new"], tolerance: 5.minutes) }.not_to raise_error
      expect { described_class.verify_timestamped!(body, header, secrets: ["old"], tolerance: 5.minutes) }.not_to raise_error
    end

    it "accepts a sender's old secret while the receiver holds both" do
      header = described_class.header(body, secrets: ["old"], at: now.to_i)
      expect { described_class.verify_timestamped!(body, header, secrets: %w[new old], tolerance: 5.minutes) }.not_to raise_error
    end

    it "rejects a wrong secret, a tampered body, a missing header and a stale timestamp" do
      good = described_class.header(body, secrets: ["s"], at: now.to_i)
      verify = ->(b, h, secrets: ["s"]) { described_class.verify_timestamped!(b, h, secrets: secrets, tolerance: 5.minutes) }

      expect { verify.call(body, good, secrets: ["other"]) }.to raise_error(described_class::Invalid, /mismatch/)
      expect { verify.call('{"id":"evt_2"}', good) }.to raise_error(described_class::Invalid, /mismatch/)
      expect { verify.call(body, "") }.to raise_error(described_class::Invalid, /missing/)
      stale = described_class.header(body, secrets: ["s"], at: 10.minutes.ago.to_i)
      expect { verify.call(body, stale) }.to raise_error(described_class::Invalid, /too old/)
    end
  end

  describe ".verify_body!" do
    it "accepts a body signed with any of the secrets and rejects anything else" do
      expect { described_class.verify_body!(body, hmac("old", body), secrets: %w[new old]) }.not_to raise_error
      expect { described_class.verify_body!(body, hmac("x", body), secrets: %w[new old]) }
        .to raise_error(described_class::Invalid, /mismatch/)
      expect { described_class.verify_body!(body, "", secrets: ["new"]) }.to raise_error(described_class::Invalid, /missing/)
    end
  end

  it "reads a comma-separated secret list, falling back to the single-secret variable" do
    stub_const("ENV", ENV.to_h.merge("X_SECRETS" => "new, old", "X_SECRET" => "single"))
    expect(described_class.secrets_from_env("X_SECRETS", "X_SECRET", "d")).to eq(%w[new old])
    stub_const("ENV", ENV.to_h.except("X_SECRETS").merge("X_SECRET" => "single"))
    expect(described_class.secrets_from_env("X_SECRETS", "X_SECRET", "d")).to eq(["single"])
  end
end
