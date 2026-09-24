# typed: strict
# frozen_string_literal: true

# Nordpay: EU cards. Separate authorize/capture, synchronous confirmation,
# partial refunds, honours X-Request-Id as an idempotency key.
class NordpayAdapter < PspAdapter
  extend T::Sig

  # The PSP simulator hangs for 30s in its timeout scenario. We give up long
  # before that: a Sidekiq thread pinned for 30s per stuck call would drain the
  # pool. 3s is also the spec's bound for the web tier.
  OPEN_TIMEOUT = 1
  READ_TIMEOUT = 3

  # webhook_secrets: current first; more than one only while rotating (#15).
  sig { params(base_url: String, api_key: String, webhook_secrets: T::Array[String]).void }
  def initialize(base_url: ENV.fetch("NORDPAY_URL", "http://localhost:4001"),
                 api_key: ENV.fetch("NORDPAY_API_KEY", "np_test_key"),
                 webhook_secrets: WebhookSignature.secrets_from_env("NORDPAY_WEBHOOK_SECRETS", "NORDPAY_WEBHOOK_SECRET", "np_whsec_test"))
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
  def name = "nordpay"

  sig { override.returns(T::Boolean) }
  def supports_partial_refund? = true

  sig { override.returns(T::Boolean) }
  def separate_authorize_and_capture? = true

  sig { override.returns(T::Array[String]) }
  def currencies = %w[EUR GBP USD]

  sig { override.params(payment: Payment).returns(Result) }
  def authorize(payment)
    response = request(:post, "/charges",
                       body: {
                         amount_minor: payment.amount_minor,
                         currency: payment.currency,
                         payment_method_token: payment.payment_method_token,
                         capture: payment.capture_on_authorize
                       },
                       headers: { "X-Request-Id" => payment.psp_reference })

    charge = extract_charge(response.body, expected_reference: payment.psp_reference)
    to_result(charge)
  end

  sig { override.params(psp_reference: String).returns(Result) }
  def fetch(psp_reference)
    response = request(:get, "/charges/#{psp_reference}")
    return not_found(psp_reference) if response.status == 404

    to_result(T.cast(response.body, T::Hash[String, T.untyped]))
  end

  sig { override.params(payment: Payment, amount_minor: Integer).returns(Result) }
  def capture(payment, amount_minor)
    response = request(:post, "/charges/#{payment.psp_reference}/capture", body: { amount_minor: amount_minor })
    return not_found(payment.psp_reference) if response.status == 404

    to_result(T.cast(response.body, T::Hash[String, T.untyped]))
  end

  sig { override.params(payment: Payment).returns(Result) }
  def cancel(payment)
    response = request(:post, "/charges/#{payment.psp_reference}/void")
    return not_found(payment.psp_reference) if response.status == 404

    to_result(T.cast(response.body, T::Hash[String, T.untyped]))
  end

  # Nordpay refunds are keyed by our refund reference via X-Request-Id, so a
  # timed-out refund is resolved by fetch_refund, never by re-sending.
  sig { override.params(refund: Refund).returns(RefundResult) }
  def refund(refund)
    response = request(:post, "/charges/#{T.must(refund.payment).psp_reference}/refunds",
                       body: { amount_minor: refund.amount_minor },
                       headers: { "X-Request-Id" => refund.psp_reference })
    return refund_not_found(refund.psp_reference) if response.status == 404

    to_refund_result(T.cast(response.body, T::Hash[String, T.untyped]))
  end

  sig { override.params(psp_reference: String).returns(RefundResult) }
  def fetch_refund(psp_reference)
    response = request(:get, "/refunds/#{psp_reference}")
    return refund_not_found(psp_reference) if response.status == 404

    to_refund_result(T.cast(response.body, T::Hash[String, T.untyped]))
  end

  # GET /settlements?date= — a CSV, one row per capture (net of fee) or refund.
  sig { override.params(date: Date).returns(T.nilable(T::Array[SettlementReportLine])) }
  def settlement_report(date)
    response = request(:get, "/settlements?date=#{date.iso8601}")
    CSV.parse(response.body.to_s, headers: true).map do |parsed|
      row = T.cast(parsed, CSV::Row) # headers: true always yields rows, never arrays
      SettlementReportLine.new(
        external_id: row.fetch("line_id"), kind: row.fetch("type"), psp_reference: row.fetch("reference"),
        refund_reference: row["refund_reference"].presence, gross_minor: Integer(row.fetch("gross_minor")),
        fee_minor: Integer(row.fetch("fee_minor")), net_minor: Integer(row.fetch("net_minor")),
        currency: row.fetch("currency"), booked_at: Time.iso8601(row.fetch("booked_at"))
      )
    end
  rescue KeyError, ArgumentError, CSV::MalformedCSVError => e
    raise Rejected.new(200, "nordpay settlement report unreadable: #{e.message}")
  end

  # Signature: X-Nordpay-Signature: <hex HMAC-SHA256 of the raw body>. Nordpay
  # signs no timestamp; that is its wire format, and we don't invent one (#15).
  # Events: { id, type: charge.authorized|charge.captured|charge.declined, created_at, data: <charge> }
  sig { override.params(raw_body: String, headers: T::Hash[String, String]).returns(WebhookEvent) }
  def verify_webhook(raw_body, headers)
    WebhookSignature.verify_body!(raw_body, headers["X-Nordpay-Signature"].to_s, secrets: @webhook_secrets)
    parse_webhook(JSON.parse(raw_body))
  rescue WebhookSignature::Invalid => e
    raise InvalidSignature, e.message
  rescue JSON::ParserError => e
    raise MalformedWebhook, e.message
  end

  sig { override.params(payload: T::Hash[String, T.untyped]).returns(WebhookEvent) }
  def parse_webhook(payload)
    data = T.cast(payload.fetch("data"), T::Hash[String, T.untyped])
    status = case data["status"]
    when "authorized" then Result::Status::Authorized
    when "captured" then Result::Status::Captured
    when "canceled" then Result::Status::Canceled
    when "declined" then Result::Status::Declined
    end
    WebhookEvent.new(
      external_id: payload.fetch("id"), event_type: payload.fetch("type"),
      psp_reference: data["reference"], psp_charge_id: data["id"], status: status, decline_code: data["code"],
      psp_timestamp: Time.iso8601(payload.fetch("created_at")), payload: payload
    )
  rescue KeyError, ArgumentError => e
    raise MalformedWebhook, e.message
  end

  private

  # Every call goes through the PSP's circuit breaker (DECISIONS #17). An open
  # circuit raises PspCircuit::Open — an Unavailable — before anything is sent.
  sig do
    params(method: Symbol, path: String, body: T.nilable(T::Hash[Symbol, T.untyped]),
           headers: T::Hash[String, String]).returns(Faraday::Response)
  end
  def request(method, path, body: nil, headers: {})
    PspCircuit.call("nordpay") { send_request(method, path, body: body, headers: headers) }
  end

  sig do
    params(method: Symbol, path: String, body: T.nilable(T::Hash[Symbol, T.untyped]),
           headers: T::Hash[String, String]).returns(Faraday::Response)
  end
  def send_request(method, path, body: nil, headers: {})
    operation = "#{method.upcase} #{path.sub(%r{/ph_[a-f0-9]+}, '/:ref')}"
    response = @conn.run_request(method, path, body, headers)
    outcome = response.status.between?(200, 299) ? "ok" : "http_#{response.status}"
    Metrics.increment(:psp_calls, psp: "nordpay", operation: operation, outcome: outcome)
    case response.status
    when 200..299, 404 then response
    when 500..599 then raise Unavailable, "nordpay #{response.status}: #{error_message(response)}"
    else raise Rejected.new(response.status, "nordpay #{response.status}: #{error_message(response)}")
    end
  rescue Faraday::TimeoutError => e
    # The request MAY have landed. Caller moves to `unknown` and fetches.
    Metrics.increment(:psp_calls, psp: "nordpay", operation: operation, outcome: "timeout")
    raise TimedOut, "nordpay #{method.upcase} #{path}: #{e.message}"
  rescue Faraday::ConnectionFailed => e
    # Never reached the PSP. Safe to retry with the same reference.
    Metrics.increment(:psp_calls, psp: "nordpay", operation: operation, outcome: "unreachable")
    raise Unavailable, "nordpay unreachable: #{e.message}"
  end

  # Nordpay can return the same charge twice in one body ({charges: [c, c]}).
  # We take the one matching our reference; a second copy is ignored, and a
  # copy with a different reference would be a PSP bug we refuse to act on.
  sig { params(body: T.untyped, expected_reference: String).returns(T::Hash[String, T.untyped]) }
  def extract_charge(body, expected_reference:)
    body = T.cast(body, T::Hash[String, T.untyped])
    candidates = body.key?("charges") ? T.cast(body["charges"], T::Array[T::Hash[String, T.untyped]]) : [body]
    candidates.find { |c| c["reference"] == expected_reference } or
      raise Rejected.new(200, "nordpay returned no charge for reference #{expected_reference}")
  end

  sig { params(charge: T::Hash[String, T.untyped]).returns(Result) }
  def to_result(charge)
    status = case charge["status"]
    when "authorized" then Result::Status::Authorized
    when "captured" then Result::Status::Captured
    when "canceled" then Result::Status::Canceled
    when "declined" then Result::Status::Declined
    else raise Rejected.new(200, "nordpay unknown charge status #{charge['status'].inspect}")
    end

    Result.new(
      status: status,
      psp_reference: charge.fetch("reference"),
      psp_charge_id: charge["id"],
      decline_code: charge["code"],
      psp_timestamp: Time.iso8601(charge.fetch("created_at")),
      raw: charge
    )
  end

  sig { params(psp_reference: String).returns(Result) }
  def not_found(psp_reference)
    Result.new(status: Result::Status::NotFound, psp_reference: psp_reference, psp_charge_id: nil,
               decline_code: nil, psp_timestamp: Time.current)
  end

  sig { params(body: T::Hash[String, T.untyped]).returns(RefundResult) }
  def to_refund_result(body)
    status = case body["status"]
    when "succeeded" then RefundResult::Status::Succeeded
    when "failed" then RefundResult::Status::Failed
    when "pending" then RefundResult::Status::Pending
    else raise Rejected.new(200, "nordpay unknown refund status #{body['status'].inspect}")
    end

    RefundResult.new(
      status: status, psp_reference: body.fetch("reference"), psp_refund_id: body["id"],
      failure_code: body["code"], psp_timestamp: Time.iso8601(body.fetch("created_at")), raw: body
    )
  end

  sig { params(psp_reference: String).returns(RefundResult) }
  def refund_not_found(psp_reference)
    RefundResult.new(status: RefundResult::Status::NotFound, psp_reference: psp_reference, psp_refund_id: nil,
                     failure_code: nil, psp_timestamp: Time.current)
  end

  sig { params(response: Faraday::Response).returns(String) }
  def error_message(response)
    body = response.body
    body.is_a?(Hash) ? body.dig("error", "message").to_s : body.to_s[0, 200]
  end
end
