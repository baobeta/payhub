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

  sig { params(base_url: String, api_key: String).void }
  def initialize(base_url: ENV.fetch("NORDPAY_URL", "http://localhost:4001"),
                 api_key: ENV.fetch("NORDPAY_API_KEY", "np_test_key"))
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

  private

  sig do
    params(method: Symbol, path: String, body: T.nilable(T::Hash[Symbol, T.untyped]),
           headers: T::Hash[String, String]).returns(Faraday::Response)
  end
  def request(method, path, body: nil, headers: {})
    response = @conn.run_request(method, path, body, headers)
    case response.status
    when 200..299, 404 then response
    when 500..599 then raise Unavailable, "nordpay #{response.status}: #{error_message(response)}"
    else raise Rejected.new(response.status, "nordpay #{response.status}: #{error_message(response)}")
    end
  rescue Faraday::TimeoutError => e
    # The request MAY have landed. Caller moves to `unknown` and fetches.
    raise TimedOut, "nordpay #{method.upcase} #{path}: #{e.message}"
  rescue Faraday::ConnectionFailed => e
    # Never reached the PSP. Safe to retry with the same reference.
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

  sig { params(response: Faraday::Response).returns(String) }
  def error_message(response)
    body = response.body
    body.is_a?(Hash) ? body.dig("error", "message").to_s : body.to_s[0, 200]
  end
end
