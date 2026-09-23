# typed: strict
# frozen_string_literal: true

# Wraps a POST so that the same Idempotency-Key from the same merchant
# produces the same response exactly once. The claim is an INSERT into a
# unique index; the outcome of that INSERT decides everything else.
class IdempotencyGuard
  extend T::Sig

  class Outcome < T::Struct
    const :status, Integer
    const :body, T::Hash[String, T.untyped]
    const :replayed, T::Boolean
  end

  sig { params(merchant: Merchant, key: String, request_method: String, path: String, raw_body: String).void }
  def initialize(merchant:, key:, request_method:, path:, raw_body:)
    @merchant = merchant
    @key = key
    @fingerprint = T.let(Digest::SHA256.hexdigest("#{request_method.upcase} #{path}\n#{raw_body}"), String)
  end

  # Runs `action` at most once for this key. The block returns [status, body].
  sig do
    params(action: T.proc.returns([Integer, T::Hash[String, T.untyped]])).returns(Outcome)
  end
  def call(&action)
    Tracing.in_span("payhub.idempotency.claim", attributes: {
      "payhub.merchant_id" => @merchant.id,
      "payhub.operation" => "claim"
    }) do |span|
      record, won = IdempotencyKey.claim!(@merchant, @key, @fingerprint)
      span.set_attribute("payhub.idempotency_outcome", won ? "won" : "existing") if span.respond_to?(:set_attribute)
      return run(record, &action) if won

      # Lost the race. Everything below reads a row someone else wrote.
      if record.expired? || record.abandoned?
        # Dead claim. Remove it and go again; a concurrent contender may beat
        # us to the re-claim, in which case the recursion takes the loser path.
        record.destroy!
        return call(&action)
      end

      if record.request_fingerprint != @fingerprint
        span.set_attribute("payhub.idempotency_outcome", "fingerprint_mismatch") if span.respond_to?(:set_attribute)
        raise ApiError.new(type: ApiError::Type::IdempotencyError, http_status: 422, code: "idempotency_key_reused",
                           message: "Idempotency-Key #{@key} was already used with a different request body",
                           param: "Idempotency-Key")
      end

      if record.in_flight?
        span.set_attribute("payhub.idempotency_outcome", "in_flight") if span.respond_to?(:set_attribute)
        raise ApiError.new(type: ApiError::Type::IdempotencyError, http_status: 409, code: "idempotency_key_in_flight",
                           message: "A request with Idempotency-Key #{@key} is still being processed; retry shortly",
                           param: "Idempotency-Key", retriable: true)
      end

      span.set_attribute("payhub.idempotency_outcome", "replayed") if span.respond_to?(:set_attribute)
      Outcome.new(status: record.response_status,
                  body: T.cast(record.response_body, T::Hash[String, T.untyped]), replayed: true)
    end
  end

  private

  sig { params(record: IdempotencyKey, action: T.proc.returns([Integer, T::Hash[String, T.untyped]])).returns(Outcome) }
  def run(record, &action)
    status, body = action.call
    if status >= 500
      # Our failure. Do not memoise it for 24h — let the merchant retry.
      record.release!
    else
      # 2xx and 4xx are both legitimate, repeatable answers to THIS request.
      record.complete!(status, body)
    end
    Outcome.new(status: status, body: body, replayed: false)
  rescue StandardError
    record.release!
    raise
  end
end
