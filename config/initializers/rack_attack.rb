# typed: false
# frozen_string_literal: true

# Per-merchant rate limiting. Keyed on the bearer key's digest (never the raw
# key — it must not land in the cache), so one merchant cannot exhaust the
# API for others. Unauthenticated requests are keyed by IP at a lower rate.
#
# 429 responses use the standard error shape with Retry-After.
class Rack::Attack
  LIMIT_PER_MINUTE = Integer(ENV.fetch("RATE_LIMIT_PER_MINUTE", 300))
  WEBHOOK_LIMIT_PER_MINUTE = 1_000 # PSPs burst on retry storms; be generous but bounded

  def self.merchant_key(req)
    auth = req.get_header("HTTP_AUTHORIZATION").to_s
    return nil unless auth.start_with?("Bearer ")

    Digest::SHA256.hexdigest(auth.delete_prefix("Bearer ").strip)
  end

  # `limit:` as a proc so it is read per request — tests can stub_const the
  # limit without re-registering the throttle (which would leak between examples).
  throttle("v1/merchant", limit: ->(_req) { LIMIT_PER_MINUTE }, period: 1.minute) do |req|
    merchant_key(req) if req.path.start_with?("/v1/") && !req.path.start_with?("/v1/webhooks/")
  end

  throttle("v1/unauthenticated-ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/v1/") && !req.path.start_with?("/v1/webhooks/") && merchant_key(req).nil?
  end

  throttle("v1/webhooks-ip", limit: WEBHOOK_LIMIT_PER_MINUTE, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/v1/webhooks/")
  end

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
    [429, { "Content-Type" => "application/json", "Retry-After" => retry_after }, [body.to_json]]
  end
end
