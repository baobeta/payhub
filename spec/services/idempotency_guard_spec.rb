require "rails_helper"

RSpec.describe IdempotencyGuard do
  let(:merchant) { create(:merchant) }

  def guard(key: "k1", body: '{"amount_minor":2500}', merchant: self.merchant)
    described_class.new(merchant: merchant, key: key, request_method: "POST", path: "/v1/payments", raw_body: body)
  end

  it "runs the action once and replays the stored response for the same key + body" do
    runs = 0
    action = -> { runs += 1; [202, { "id" => "pay_1" }] }

    first = guard.call(&action)
    second = guard.call(&action)

    expect(runs).to eq(1)
    expect(first).to have_attributes(status: 202, body: { "id" => "pay_1" }, replayed: false)
    expect(second).to have_attributes(status: 202, body: { "id" => "pay_1" }, replayed: true)
  end

  it "scopes keys per merchant — two merchants can use the same key independently" do
    runs = 0
    action = -> { runs += 1; [202, {}] }

    guard(merchant: create(:merchant)).call(&action)
    guard(merchant: create(:merchant)).call(&action)

    expect(runs).to eq(2)
  end

  it "rejects the same key with a different body as 422 idempotency_error, without running the action" do
    guard.call { [202, {}] }

    expect { guard(body: '{"amount_minor":9000}').call { raise "must not run" } }
      .to raise_error(ApiError) { |e| expect(e).to have_attributes(http_status: 422, code: "idempotency_key_reused") }
  end

  it "answers 409 (retriable) while the first request is still in flight" do
    IdempotencyKey.claim!(merchant, "k1", guard.instance_variable_get(:@fingerprint)) # simulate an open claim

    expect { guard.call { raise "must not run" } }
      .to raise_error(ApiError) { |e| expect(e).to have_attributes(http_status: 409, retriable: true) }
  end

  it "memoises a 4xx (it is a repeatable answer) but releases a 5xx (it is our bug)" do
    guard(key: "bad").call { [422, { "error" => "x" }] }
    expect(guard(key: "bad").call { raise "must not run" }).to have_attributes(status: 422, replayed: true)

    guard(key: "boom").call { [500, {}] }
    expect(IdempotencyKey.find_by(key: "boom")).to be_nil
    expect(guard(key: "boom").call { [202, {}] }).to have_attributes(status: 202, replayed: false)
  end

  it "releases the claim if the action raises, so the merchant can retry" do
    expect { guard.call { raise "db down" } }.to raise_error(RuntimeError, "db down")
    expect(IdempotencyKey.count).to eq(0)
  end

  it "re-takes an abandoned claim (locked, no response, older than LOCK_TIMEOUT)" do
    record, = IdempotencyKey.claim!(merchant, "k1", guard.instance_variable_get(:@fingerprint))
    record.update_column(:locked_at, 2.minutes.ago)

    expect(guard.call { [202, { "fresh" => true }] }).to have_attributes(status: 202, replayed: false)
    expect(IdempotencyKey.count).to eq(1)
  end

  it "treats an expired key as absent" do
    guard.call { [202, { "v" => 1 }] }
    IdempotencyKey.update_all(expires_at: 1.hour.ago)

    expect(guard.call { [202, { "v" => 2 }] }).to have_attributes(body: { "v" => 2 }, replayed: false)
  end

  # ── The concurrency test the spec asks for: real threads, real connections ──
  #
  # No transactional fixture here: each thread needs its own committed view
  # so the unique index, not Ruby, is what arbitrates. The winner runs the
  # action; every loser gets 409 (still in flight) or a replay (finished).
  # Under no interleaving does the action run twice.
  it "lets exactly one of N simultaneous identical requests run the action", :concurrency do
    # N must be < the connection pool size (RAILS_MAX_THREADS, default 5; the
    # main thread holds one). With N > pool, threads holding a connection wait
    # at the barrier for threads that are waiting for a connection: deadlock.
    contenders = 4
    merchant = create(:merchant)
    runs = Concurrent::AtomicFixnum.new(0)
    barrier = Concurrent::CyclicBarrier.new(contenders)
    outcomes = Concurrent::Array.new

    threads = contenders.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait # all 8 hit claim! within the same few microseconds
          g = described_class.new(merchant: merchant, key: "race", request_method: "POST",
                                  path: "/v1/payments", raw_body: "{}")
          outcomes << g.call { runs.increment; sleep 0.05; [202, { "id" => "one" }] }
        rescue ApiError => e
          outcomes << e.http_status
        end
      end
    end
    threads.each(&:join)

    expect(runs.value).to eq(1)
    expect(outcomes.size).to eq(contenders)
    winners = outcomes.count { |o| o.is_a?(IdempotencyGuard::Outcome) && !o.replayed }
    expect(winners).to eq(1)
    expect(outcomes.reject { |o| o.is_a?(IdempotencyGuard::Outcome) }).to all(eq(409))
    expect(IdempotencyKey.where(merchant: merchant, key: "race").count).to eq(1)
  end
end
