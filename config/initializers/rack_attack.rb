# typed: false
# frozen_string_literal: true

# Rate limits (TEST_CASES L6).
#
# /v1 is budgeted per MERCHANT, across all of its keys, with separate live and
# test budgets: 300/min live, 75/min test — Stripe's 4:1 live:sandbox ratio
# (https://docs.stripe.com/rate-limits). Account-wide rather than per
# credential, like Checkout.com
# (https://www.checkout.com/docs/developer-resources/api/api-rate-limits), so
# minting more keys does not buy more throughput. The bearer key is resolved
# to its merchant through its SHA-256 digest; the lookup is cached for a
# minute under the digest (never the raw key — it must not land in the cache).
# A key that resolves to nothing (unknown, revoked, expired) is treated as
# unauthenticated and keyed by IP at a lower rate.
#
# The dashboard and ops APIs are throttled per signed-in session. The sign-in
# endpoints are excluded: they keep their own per-IP throttle below.
#
# 429 responses use the standard error shape with Retry-After and
# PayHub-Rate-Limited-Reason (Stripe's Stripe-Rate-Limited-Reason).
class Rack::Attack
  LIMIT_PER_MINUTE = Integer(ENV.fetch("RATE_LIMIT_PER_MINUTE", 300))
  TEST_LIMIT_PER_MINUTE = Integer(ENV.fetch("RATE_LIMIT_TEST_PER_MINUTE", 75))
  SESSION_LIMIT_PER_MINUTE = 300
  WEBHOOK_LIMIT_PER_MINUTE = 1_000 # PSPs burst on retry storms; be generous but bounded

  KEY_CACHE_PREFIX = "rate_limit:api_key:"
  KEY_CACHE_TTL = 1.minute # a revoked key keeps its merchant's budget this long; auth still refuses it
  SIGN_IN_PATH = %r{\A/(dashboard|ops)/api/(session(/otp|/recovery|/step_up)?|otp/confirm)\z}
  OWNER_ENV = "payhub.rate_limit.key_owner"

  # TC-L6-5: the shape of a key ApiKey.issue! mints (sk_live_/sk_test_ + 48
  # hex), with room for older keys. Anything else cannot resolve to a merchant,
  # so it costs no database or cache lookup and falls to the per-IP throttle.
  KEY_SHAPE = /\Ask_(live|test)_[A-Za-z0-9]{16,96}\z/

  def self.key_digest(req)
    auth = req.get_header("HTTP_AUTHORIZATION").to_s
    return nil unless auth.start_with?("Bearer ")

    raw = auth.delete_prefix("Bearer ").strip
    Merchant.digest(raw) if raw.match?(KEY_SHAPE)
  end

  def self.v1_api?(req) = req.path.start_with?("/v1/") && !req.path.start_with?("/v1/webhooks/")

  # [merchant_id, livemode] of the bearer key, or nil. Memoised on the request
  # because three throttles ask; cached across requests so the hot path skips the DB.
  # A miss is not cached (skip_nil): random well-formed keys must not fill the
  # cache, and a key issued a moment ago must not read as unknown for a minute.
  def self.key_owner(req)
    return req.env[OWNER_ENV] if req.env.key?(OWNER_ENV)

    digest = key_digest(req)
    req.env[OWNER_ENV] = digest && Rails.cache.fetch("#{KEY_CACHE_PREFIX}#{digest}", expires_in: KEY_CACHE_TTL,
                                                                                     skip_nil: true) do
      ApiKey.active.where(digest:).pick(:merchant_id, :livemode)
    end
  end

  # The signed session id from the dashboard or ops cookie. Rails has already
  # put the key generator in env (Rails::Engine#build_request), so the signed
  # jar verifies here exactly as in the controller; a forged cookie reads nil.
  def self.session_key(req)
    return nil unless req.path.match?(%r{\A/(dashboard|ops)/api/}) && !req.path.match?(SIGN_IN_PATH)

    name = req.path.start_with?("/ops/") ? Ops::Api::BaseController::COOKIE : Dashboard::Api::BaseController::COOKIE
    id = ActionDispatch::Request.new(req.env).cookie_jar.signed[name]
    "#{name}:#{id}" if id
  end

  # `limit:` as a proc so it is read per request — tests can stub_const the
  # limit without re-registering the throttle (which would leak between examples).
  throttle("v1/merchant-live", limit: ->(_req) { LIMIT_PER_MINUTE }, period: 1.minute) do |req|
    owner = key_owner(req) if v1_api?(req)
    owner[0] if owner && owner[1]
  end

  throttle("v1/merchant-test", limit: ->(_req) { TEST_LIMIT_PER_MINUTE }, period: 1.minute) do |req|
    owner = key_owner(req) if v1_api?(req)
    owner[0] if owner && !owner[1]
  end

  throttle("v1/unauthenticated-ip", limit: 30, period: 1.minute) do |req|
    req.ip if v1_api?(req) && key_owner(req).nil?
  end

  throttle("v1/webhooks-ip", limit: WEBHOOK_LIMIT_PER_MINUTE, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/v1/webhooks/")
  end

  throttle("ui/session", limit: ->(_req) { SESSION_LIMIT_PER_MINUTE }, period: 1.minute) do |req|
    session_key(req)
  end

  # Password and code guessing. The per-account lockout (10 failures) is the
  # real control; this one stops one IP spraying many accounts.
  throttle("ui/sign-in-ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(SIGN_IN_PATH)
  end

  # Stripe's vocabulary: a budget for the caller as a whole is "global-rate";
  # one endpoint's own budget is "endpoint-rate".
  REASONS = Hash.new("global-rate").merge("ui/sign-in-ip" => "endpoint-rate").freeze

  self.throttled_responder = lambda do |req|
    match = req.env["rack.attack.match_data"]
    retry_after = (match[:period] - (Time.now.to_i % match[:period])).to_s
    body = {
      error: {
        type: "rate_limit", code: "rate_limited",
        message: "Too many requests; retry after #{retry_after}s",
        param: nil, retriable: true, request_id: req.env["action_dispatch.request_id"]
      }
    }
    [429, { "Content-Type" => "application/json", "Retry-After" => retry_after,
            "PayHub-Rate-Limited-Reason" => REASONS[req.env["rack.attack.matched"]] }, [body.to_json]]
  end
end
