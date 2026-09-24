# typed: strict
# frozen_string_literal: true

# One circuit breaker per PSP (DECISIONS #17). Every adapter call goes
# through it. Its state lives in Redis, so every web and worker process sees
# the same circuit.
#
#   closed     calls pass; each outcome lands in a 30s sliding window
#   open       at least MIN_CALLS in the window and FAILURE_RATIO of them
#              failed: calls are refused BEFORE anything is sent, for COOLDOWN
#   half-open  after COOLDOWN exactly one call (the probe) goes through;
#              success closes the circuit, failure opens it again
#
# A failure is an ambiguous or unavailable PSP — TimedOut or Unavailable. A
# decline, a 404 or a 4xx is the PSP answering, and counts as success.
#
# Refusing is always safe: an Open request was never sent, so the caller's
# usual Unavailable handling (retry the job, skip this sweep, 503) applies,
# and nothing becomes `unknown`. That is also the ONLY condition under which
# a future failover to another PSP could be allowed — see DECISIONS #17.
class PspCircuit
  extend T::Sig

  # Raised instead of calling the PSP. An Unavailable: the request never left.
  class Open < PspAdapter::Unavailable; end

  BUCKET_SECONDS = 10
  WINDOW_BUCKETS = 3 # a 30-second sliding window
  MIN_CALLS = 10
  FAILURE_RATIO = 0.5
  COOLDOWN_SECONDS = 30
  PROBE_TTL_SECONDS = 15 # a probe that never reports back frees the slot

  class << self
    extend T::Sig

    sig do
      type_parameters(:R).params(psp: String, blk: T.proc.returns(T.type_parameter(:R)))
                         .returns(T.type_parameter(:R))
    end
    def call(psp, &blk)
      new(psp, store).call(&blk)
    end

    # Redis everywhere except the test suite, whose examples must not share
    # (or leak) circuit state through a real server.
    sig { returns(Store) }
    def store
      @store ||= T.let(Rails.env.test? ? MemoryStore.new : RedisStore.new, T.nilable(Store))
    end

    sig { params(store: T.nilable(Store)).void }
    attr_writer :store
  end

  sig { params(psp: String, store: Store).void }
  def initialize(psp, store)
    @psp = psp
    @store = store
  end

  sig { type_parameters(:R).params(blk: T.proc.returns(T.type_parameter(:R))).returns(T.type_parameter(:R)) }
  def call(&blk)
    probe = admit!
    begin
      result = blk.call
    rescue PspAdapter::TimedOut, PspAdapter::Unavailable
      failed!(probe)
      raise
    end
    succeeded!(probe)
    result
  end

  private

  # Returns true when this call is the half-open probe; raises Open when the
  # circuit refuses it.
  sig { returns(T::Boolean) }
  def admit!
    open_until = @store.get(key("open_until"))
    return false unless open_until
    raise Open, "#{@psp} circuit open until #{Time.at(open_until.to_f).utc.iso8601}" if now < open_until.to_f
    return true if @store.set_nx(key("probe"), "1", ttl: PROBE_TTL_SECONDS)

    raise Open, "#{@psp} circuit half-open; a probe is already in flight"
  end

  sig { params(probe: T::Boolean).void }
  def succeeded!(probe)
    probe ? close! : record(failed: false)
  end

  sig { params(probe: T::Boolean).void }
  def failed!(probe)
    return trip!("probe failed") if probe

    record(failed: true)
    calls, fails = window
    trip!("#{fails}/#{calls} calls failed in #{BUCKET_SECONDS * WINDOW_BUCKETS}s") if calls >= MIN_CALLS && fails >= calls * FAILURE_RATIO
  end

  sig { params(reason: String).void }
  def trip!(reason)
    @store.set(key("open_until"), (now + COOLDOWN_SECONDS).to_s, ttl: 3600)
    @store.del([key("probe"), *window_keys])
    Metrics.increment(:psp_circuit_opened, psp: @psp)
    Rails.logger.error({ event: "psp_circuit.opened", psp: @psp, reason: reason, cooldown_s: COOLDOWN_SECONDS }.to_json)
  end

  sig { void }
  def close!
    @store.del([key("open_until"), key("probe"), *window_keys])
    Rails.logger.info({ event: "psp_circuit.closed", psp: @psp }.to_json)
  end

  sig { params(failed: T::Boolean).void }
  def record(failed:)
    ttl = BUCKET_SECONDS * (WINDOW_BUCKETS + 1)
    @store.incr(bucket_key(current_bucket, "calls"), ttl: ttl)
    @store.incr(bucket_key(current_bucket, "fails"), ttl: ttl) if failed
  end

  sig { returns([Integer, Integer]) }
  def window
    calls = 0
    fails = 0
    @store.mget(window_keys).each_slice(2) do |c, f|
      calls += c.to_i
      fails += f.to_i
    end
    [calls, fails]
  end

  sig { returns(T::Array[String]) }
  def window_keys
    (0...WINDOW_BUCKETS).flat_map do |i|
      bucket = current_bucket - i
      [bucket_key(bucket, "calls"), bucket_key(bucket, "fails")]
    end
  end

  sig { returns(Integer) }
  def current_bucket = (now / BUCKET_SECONDS).floor

  sig { params(bucket: Integer, kind: String).returns(String) }
  def bucket_key(bucket, kind) = key("#{bucket}:#{kind}")

  sig { params(suffix: String).returns(String) }
  def key(suffix) = "psp_circuit:#{@psp}:#{suffix}"

  sig { returns(Float) }
  def now = Time.current.to_f

  # The six operations the breaker needs; two implementations.
  module Store
    extend T::Sig
    extend T::Helpers
    interface!

    sig { abstract.params(key: String).returns(T.nilable(String)) }
    def get(key); end

    sig { abstract.params(keys: T::Array[String]).returns(T::Array[T.nilable(String)]) }
    def mget(keys); end

    sig { abstract.params(key: String, value: String, ttl: Integer).void }
    def set(key, value, ttl:); end

    # Sets only if absent; true when this caller set it.
    sig { abstract.params(key: String, value: String, ttl: Integer).returns(T::Boolean) }
    def set_nx(key, value, ttl:); end

    sig { abstract.params(key: String, ttl: Integer).void }
    def incr(key, ttl:); end

    sig { abstract.params(keys: T::Array[String]).void }
    def del(keys); end
  end

  class RedisStore
    extend T::Sig
    include Store

    sig { override.params(key: String).returns(T.nilable(String)) }
    def get(key) = redis { |r| r.call("GET", key) }

    sig { override.params(keys: T::Array[String]).returns(T::Array[T.nilable(String)]) }
    def mget(keys) = redis { |r| r.call("MGET", *keys) }

    sig { override.params(key: String, value: String, ttl: Integer).void }
    def set(key, value, ttl:) = redis { |r| r.call("SET", key, value, "EX", ttl) }

    sig { override.params(key: String, value: String, ttl: Integer).returns(T::Boolean) }
    def set_nx(key, value, ttl:) = redis { |r| r.call("SET", key, value, "NX", "EX", ttl) } == "OK"

    # INCR and EXPIRE in one round trip, so a counter can never outlive its window.
    sig { override.params(key: String, ttl: Integer).void }
    def incr(key, ttl:) = redis { |r| r.pipelined { |p| p.call("INCR", key); p.call("EXPIRE", key, ttl) } }

    sig { override.params(keys: T::Array[String]).void }
    def del(keys) = redis { |r| r.call("DEL", *keys) }

    private

    sig { params(blk: T.proc.params(r: T.untyped).returns(T.untyped)).returns(T.untyped) }
    def redis(&blk) = Sidekiq.redis(&blk)
  end

  # Per-process, for the test suite.
  class MemoryStore
    extend T::Sig
    include Store

    sig { void }
    def initialize
      @data = T.let({}, T::Hash[String, [String, Float]])
      @mutex = T.let(Mutex.new, Mutex)
    end

    sig { override.params(key: String).returns(T.nilable(String)) }
    def get(key)
      @mutex.synchronize { live(key) }
    end

    sig { override.params(keys: T::Array[String]).returns(T::Array[T.nilable(String)]) }
    def mget(keys)
      @mutex.synchronize { keys.map { |k| live(k) } }
    end

    sig { override.params(key: String, value: String, ttl: Integer).void }
    def set(key, value, ttl:)
      @mutex.synchronize { @data[key] = [value, Time.current.to_f + ttl] }
    end

    sig { override.params(key: String, value: String, ttl: Integer).returns(T::Boolean) }
    def set_nx(key, value, ttl:)
      @mutex.synchronize do
        next false if live(key)

        @data[key] = [value, Time.current.to_f + ttl]
        true
      end
    end

    sig { override.params(key: String, ttl: Integer).void }
    def incr(key, ttl:)
      @mutex.synchronize { @data[key] = [(live(key).to_i + 1).to_s, Time.current.to_f + ttl] }
    end

    sig { override.params(keys: T::Array[String]).void }
    def del(keys)
      @mutex.synchronize { keys.each { |k| @data.delete(k) } }
    end

    sig { void }
    def clear!
      @mutex.synchronize { @data.clear }
    end

    private

    sig { params(key: String).returns(T.nilable(String)) }
    def live(key)
      value, expires_at = @data[key]
      value if expires_at && expires_at > Time.current.to_f
    end
  end
end
