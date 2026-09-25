# typed: strict
# frozen_string_literal: true

# Kiripay: SEA e-wallets. Capture-only, redirect then webhook-only
# confirmation, full refunds only, VND has no minor unit, and NO idempotency
# header — so we dedupe ourselves via merchant_reference (DECISIONS #12).
class KiripayAdapter < PspAdapter
  extend T::Sig

  OPEN_TIMEOUT = 1
  READ_TIMEOUT = 3
  # Reject webhooks whose signature timestamp is too old: replay protection.
  SIGNATURE_TOLERANCE = T.let(5.minutes, ActiveSupport::Duration)

  # webhook_secrets: current first; more than one only while rotating (#15).
  sig { params(base_url: String, api_key: String, webhook_secrets: T::Array[String]).void }
  def initialize(base_url: ENV.fetch("KIRIPAY_URL", "http://localhost:4002"),
                 api_key: ENV.fetch("KIRIPAY_API_KEY", "kp_test_key"),
                 webhook_secrets: WebhookSignature.secrets_from_env("KIRIPAY_WEBHOOK_SECRETS", "KIRIPAY_WEBHOOK_SECRET", "kp_whsec_test"))
    @webhook_secrets = webhook_secrets
    @conn = T.let(
      Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.options.open_timeout = OPEN_TIMEOUT
        f.options.timeout = READ_TIMEOUT
        f.headers["Authorization"] = "Bearer #{api_key}"
        f.adapter Faraday.default_adapter
      end,
      Faraday::Connection
    )
  end

  sig { override.returns(String) }
  def name = "kiripay"

  sig { override.returns(T::Boolean) }
  def supports_partial_refund? = false

  sig { override.returns(T::Boolean) }
  def separate_authorize_and_capture? = false

  sig { override.returns(T::Array[String]) }
  def currencies = %w[VND THB IDR]

  # "Authorize" for a capture-only PSP means: create the charge and hand back
  # the redirect. The charge completes later, by webhook. Our psp_reference
  # travels as merchant_reference — Kiripay stores it but does not dedupe on it.
  sig { override.params(payment: Payment).returns(Result) }
  def authorize(payment)
    response = request(:post, "/charges",
                       body: {
                         amount: Currency.to_major(payment.amount_minor, payment.currency).to_s("F").sub(/\.0+\z/, ""),
                         currency: payment.currency,
                         wallet_token: payment.payment_method_token,
                         merchant_reference: payment.psp_reference
                       })
    to_result(T.cast(response.body, T::Hash[String, T.untyped]), payment.psp_reference)
  end

  # THE dedupe. Kiripay may hold 0, 1 or N charges for our reference. None →
  # NotFound (safe to resend). One → it. Several → the earliest is the real
  # one; the rest are duplicates Kiripay created for a request we retried,
  # and they are logged for the reconciliation job to void.
  sig { override.params(psp_reference: String).returns(Result) }
  def fetch(psp_reference)
    response = request(:get, "/charges", params: { merchant_reference: psp_reference })
    charges = T.cast(T.cast(response.body, T::Hash[String, T.untyped]).fetch("data", []), T::Array[T::Hash[String, T.untyped]])
    return not_found(psp_reference) if charges.empty?

    if charges.size > 1
      Rails.logger.warn({ event: "kiripay.duplicate_charges", psp_reference: psp_reference,
                          charge_ids: charges.map { |c| c["id"] } }.to_json)
    end
    to_result(T.must(charges.first), psp_reference)
  end

  # Capture-only: there is nothing to capture separately. CapturePayment never
  # reaches here for Kiripay (no `authorized` state to capture from), so this
  # is a contract violation if called.
  sig { override.params(payment: Payment, amount_minor: Integer).returns(Result) }
  def capture(payment, amount_minor)
    raise Rejected.new(400, "kiripay has no separate capture step")
  end

  sig { override.params(payment: Payment).returns(Result) }
  def cancel(payment)
    raise Rejected.new(400, "kiripay charges cannot be voided; refund after capture instead")
  end

  # Full refund only. CreateRefund has already rejected partials; we still
  # send no amount so Kiripay refunds the whole charge by its own rule.
  sig { override.params(refund: Refund).returns(RefundResult) }
  def refund(refund)
    payment = T.must(refund.payment)
    charge = fetch(payment.psp_reference)
    raise Rejected.new(404, "kiripay charge not found for #{payment.psp_reference}") if charge.not_found?

    response = request(:post, "/charges/#{charge.psp_charge_id}/refunds", body: {})
    to_refund_result(T.cast(response.body, T::Hash[String, T.untyped]), refund.psp_reference)
  end

  # Kiripay refunds carry Kiripay's id, not ours, and there is exactly one
  # possible refund per charge (full only). So a refund is resolved by
  # re-reading the CHARGE: status "refunded" means our refund succeeded.
  sig { override.params(psp_reference: String).returns(RefundResult) }
  def fetch_refund(psp_reference)
    refund = Refund.find_by(psp_reference: psp_reference)
    return refund_not_found(psp_reference) unless refund

    charge = fetch(T.must(refund.payment).psp_reference)
    return refund_not_found(psp_reference) if charge.not_found?

    status = charge.raw["status"] == "refunded" ? RefundResult::Status::Succeeded : RefundResult::Status::Pending
    RefundResult.new(status: status, psp_reference: psp_reference, psp_refund_id: nil, failure_code: nil,
                     psp_timestamp: Time.current, raw: charge.raw)
  end

  # Kiripay publishes no settlement report we can fetch (DECISIONS #18).
  sig { override.params(date: Date).returns(T.nilable(T::Array[SettlementReportLine])) }
  def settlement_report(date) = nil

  # Signature: X-Kiripay-Signature: t=<unix>,v1=<hex HMAC-SHA256 of "<t>.<body>">[,v1=…]
  sig { override.params(raw_body: String, headers: T::Hash[String, String]).returns(WebhookEvent) }
  def verify_webhook(raw_body, headers)
    WebhookSignature.verify_timestamped!(raw_body, headers["X-Kiripay-Signature"].to_s,
                                         secrets: @webhook_secrets, tolerance: SIGNATURE_TOLERANCE)
    parse_webhook(JSON.parse(raw_body))
  rescue WebhookSignature::Invalid => e
    raise InvalidSignature, e.message
  rescue JSON::ParserError => e
    raise MalformedWebhook, e.message
  end

  sig { override.params(payload: T::Hash[String, T.untyped]).returns(WebhookEvent) }
  def parse_webhook(payload)
    data = T.cast(payload.fetch("data"), T::Hash[String, T.untyped])
    WebhookEvent.new(
      external_id: payload.fetch("id"),
      event_type: payload.fetch("type"),
      psp_reference: data["merchant_reference"],
      psp_charge_id: data["id"],
      status: status_from(data["status"]),
      decline_code: data["code"],
      psp_timestamp: Time.iso8601(payload.fetch("created_at")),
      payload: payload
    )
  rescue KeyError, ArgumentError => e
    raise MalformedWebhook, e.message
  end

  private

  # Every call goes through the PSP's circuit breaker (DECISIONS #17). An open
  # circuit raises PspCircuit::Open — an Unavailable — before anything is sent.
  sig do
    params(method: Symbol, path: String, body: T.nilable(T::Hash[Symbol, T.untyped]),
           params: T::Hash[String, String]).returns(Faraday::Response)
  end
  def request(method, path, body: nil, params: {})
    PspCircuit.call("kiripay") { send_request(method, path, body: body, params: params) }
  end

  sig do
    params(method: Symbol, path: String, body: T.nilable(T::Hash[Symbol, T.untyped]),
           params: T::Hash[String, String]).returns(Faraday::Response)
  end
  def send_request(method, path, body: nil, params: {})
    operation = "#{method.upcase} #{path.sub(%r{/kp_[a-f0-9]+}, '/:id')}"
    started_at = Time.current
    response = @conn.run_request(method, path, body, {}) { |req| req.params.update(params) }
    outcome = response.status.between?(200, 299) ? "ok" : "http_#{response.status}"
    Metrics.increment(:psp_calls, psp: "kiripay", operation: operation, outcome: outcome)
    PspCallLog.record(psp: "kiripay", method:, path:, params:, request_body: body, status: response.status,
                      response_body: response.body, outcome: outcome == "ok" ? "ok" : "http_error", started_at:)
    case response.status
    when 200..299, 404 then response
    when 500..599 then raise Unavailable, "kiripay #{response.status}"
    else raise Rejected.new(response.status, "kiripay #{response.status}: #{response.body.inspect[0, 200]}")
    end
  rescue Faraday::TimeoutError => e
    Metrics.increment(:psp_calls, psp: "kiripay", operation: operation, outcome: "timeout")
    PspCallLog.record(psp: "kiripay", method:, path:, params:, request_body: body, status: nil, response_body: nil,
                      outcome: "timeout", started_at: T.must(started_at))
    raise TimedOut, "kiripay #{method.upcase} #{path}: #{e.message}"
  rescue Faraday::ConnectionFailed => e
    Metrics.increment(:psp_calls, psp: "kiripay", operation: operation, outcome: "unreachable")
    PspCallLog.record(psp: "kiripay", method:, path:, params:, request_body: body, status: nil, response_body: nil,
                      outcome: "unreachable", started_at: T.must(started_at))
    raise Unavailable, "kiripay unreachable: #{e.message}"
  end

  sig { params(raw: T.nilable(String)).returns(T.nilable(Result::Status)) }
  def status_from(raw)
    case raw
    when "pending_redirect" then Result::Status::RequiresAction
    when "captured", "refunded" then Result::Status::Captured
    when "declined" then Result::Status::Declined
    end
  end

  sig { params(charge: T::Hash[String, T.untyped], psp_reference: String).returns(Result) }
  def to_result(charge, psp_reference)
    status = status_from(charge["status"]) or
      raise Rejected.new(200, "kiripay unknown charge status #{charge['status'].inspect}")

    Result.new(
      status: status, psp_reference: psp_reference, psp_charge_id: charge["id"], decline_code: charge["code"],
      psp_timestamp: Time.iso8601(charge.fetch("captured_at", charge.fetch("created_at"))),
      redirect_url: charge["redirect_url"], raw: charge
    )
  end

  sig { params(body: T::Hash[String, T.untyped], psp_reference: String).returns(RefundResult) }
  def to_refund_result(body, psp_reference)
    status = body["status"] == "succeeded" ? RefundResult::Status::Succeeded : RefundResult::Status::Failed
    RefundResult.new(status: status, psp_reference: psp_reference, psp_refund_id: body["id"], failure_code: body["code"],
                     psp_timestamp: Time.iso8601(body.fetch("created_at")), raw: body)
  end

  sig { params(psp_reference: String).returns(Result) }
  def not_found(psp_reference)
    Result.new(status: Result::Status::NotFound, psp_reference: psp_reference, psp_charge_id: nil,
               decline_code: nil, psp_timestamp: Time.current)
  end

  sig { params(psp_reference: String).returns(RefundResult) }
  def refund_not_found(psp_reference)
    RefundResult.new(status: RefundResult::Status::NotFound, psp_reference: psp_reference, psp_refund_id: nil,
                     failure_code: nil, psp_timestamp: Time.current)
  end
end
