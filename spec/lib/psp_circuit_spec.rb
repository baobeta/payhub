require "rails_helper"

RSpec.describe PspCircuit do
  def ok = described_class.call("nordpay") { :ok }
  def fail_with(error = PspAdapter::Unavailable) = described_class.call("nordpay") { raise error, "down" }

  def attempt(&)
    yield
  rescue PspAdapter::Unavailable, PspAdapter::TimedOut
    nil
  end

  it "stays closed under a flaky PSP: 20% failures never trip it" do
    50.times { |i| attempt { (i % 5).zero? ? fail_with : ok } }
    expect(ok).to eq(:ok)
  end

  it "opens once half the calls in the window fail, and then refuses without calling the PSP" do
    5.times { ok }
    5.times { attempt { fail_with(PspAdapter::TimedOut) } } # timeouts count: the PSP is not answering

    called = false
    expect { described_class.call("nordpay") { called = true } }.to raise_error(PspCircuit::Open)
    expect(called).to be(false)
  end

  it "needs a minimum number of calls: two failures out of two do not open it" do
    2.times { attempt { fail_with } }
    expect(ok).to eq(:ok)
  end

  it "does not count a PSP that answers — a decline or a 4xx is not an outage" do
    10.times { attempt { described_class.call("nordpay") { raise PspAdapter::Rejected.new(422, "bad") } rescue nil } }
    expect(ok).to eq(:ok)
  end

  it "lets exactly one probe through after the cooldown; success closes it" do
    10.times { attempt { fail_with } }

    travel (described_class::COOLDOWN_SECONDS + 1).seconds do
      probe_seen = described_class.call("nordpay") do
        # while the probe is in flight, everyone else is still refused
        expect { ok }.to raise_error(PspCircuit::Open, /probe/)
        :probed
      end
      expect(probe_seen).to eq(:probed)
      expect(ok).to eq(:ok)
    end
  end

  it "re-opens when the probe fails" do
    10.times { attempt { fail_with } }

    travel (described_class::COOLDOWN_SECONDS + 1).seconds do
      attempt { fail_with }
      expect { ok }.to raise_error(PspCircuit::Open, /open until/)
    end
  end

  it "keeps one circuit per PSP" do
    10.times { attempt { fail_with } }
    expect(described_class.call("kiripay") { :fine }).to eq(:fine)
  end

  it "is an Unavailable, so every caller's existing retry/skip path applies" do
    expect(PspCircuit::Open.ancestors).to include(PspAdapter::Unavailable)
  end

  describe PspCircuit::RedisStore do
    # The production store, against the real Redis the suite already needs for Sidekiq.
    subject(:store) { described_class.new }

    let(:key) { "psp_circuit:spec:#{SecureRandom.hex(4)}" }

    after { store.del([key, "#{key}:n"]) }

    it "implements get/set/set_nx/incr/mget/del with expiry" do
      expect(store.set_nx(key, "a", ttl: 5)).to be(true)
      expect(store.set_nx(key, "b", ttl: 5)).to be(false)
      expect(store.get(key)).to eq("a")
      2.times { store.incr("#{key}:n", ttl: 5) }
      expect(store.mget([key, "#{key}:n"])).to eq(%w[a 2])
      store.del([key])
      expect(store.get(key)).to be_nil
    end
  end
end
