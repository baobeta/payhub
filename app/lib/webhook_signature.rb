# typed: strict
# frozen_string_literal: true

# HMAC-SHA256 webhook signatures, both directions, with room for secret
# rotation (DECISIONS #15). Every verifier takes a LIST of secrets: during a
# rotation the old and new are both valid, so neither side has to switch at
# the same instant as the other.
#
#   timestamped: "t=<unix>,v1=<hex HMAC of "<t>.<body>">[,v1=…]"  (Kiripay, PayHub → merchants)
#   body-only:   "<hex HMAC of body>"                              (Nordpay — its wire format, not ours)
module WebhookSignature
  extend T::Sig

  class Invalid < StandardError; end

  class << self
    extend T::Sig

    # Header for an outbound webhook: one v1 per active secret, so a receiver
    # holding either the old or the new secret accepts it (Stripe's scheme).
    sig { params(body: String, secrets: T::Array[String], at: Integer).returns(String) }
    def header(body, secrets:, at:)
      (["t=#{at}"] + secrets.map { |s| "v1=#{hmac(s, "#{at}.#{body}")}" }).join(",")
    end

    # Accepts the header if any v1 matches any secret, and the signed
    # timestamp is within `tolerance` of now — a captured webhook cannot be
    # replayed later, even under a fresh event id.
    sig do
      params(body: String, header: String, secrets: T::Array[String], tolerance: ActiveSupport::Duration,
             now: T.any(Time, ActiveSupport::TimeWithZone)).void
    end
    def verify_timestamped!(body, header, secrets:, tolerance:, now: Time.current)
      ts = T.let(nil, T.nilable(String))
      given = T.let([], T::Array[String])
      header.split(",").each do |pair|
        key, value = pair.strip.split("=", 2)
        ts = value if key == "t"
        given << value.to_s if key == "v1"
      end
      raise Invalid, "missing signature" if ts.to_s.empty? || given.empty?
      raise Invalid, "signature mismatch" unless match?(secrets.map { |s| hmac(s, "#{ts}.#{body}") }, given)
      raise Invalid, "signature too old" if (now.to_i - ts.to_i).abs > tolerance.to_i
    end

    # A PSP that signs the body only. No timestamp to check: replay of an
    # event we already stored is stopped by the unique event id (#4).
    sig { params(body: String, given: String, secrets: T::Array[String]).void }
    def verify_body!(body, given, secrets:)
      raise Invalid, "missing signature" if given.empty?
      raise Invalid, "signature mismatch" unless match?(secrets.map { |s| hmac(s, body) }, [given])
    end

    # "NEW,OLD" in `list_var`, else the single-secret variable. The first
    # secret is the current one.
    sig { params(list_var: String, single_var: String, default: String).returns(T::Array[String]) }
    def secrets_from_env(list_var, single_var, default)
      ENV.fetch(list_var) { ENV.fetch(single_var, default) }.split(",").map(&:strip).reject(&:empty?)
    end

    private

    # Every pair is compared, in constant time, with no early exit: the
    # timing reveals neither which secret matched nor where a guess diverged.
    sig { params(expected: T::Array[String], given: T::Array[String]).returns(T::Boolean) }
    def match?(expected, given)
      expected.product(given).map { |e, g| ActiveSupport::SecurityUtils.secure_compare(e, g) }.any?
    end

    sig { params(secret: String, data: String).returns(String) }
    def hmac(secret, data) = OpenSSL::HMAC.hexdigest("SHA256", secret, data)
  end
end
