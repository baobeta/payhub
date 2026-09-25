# typed: strict
# frozen_string_literal: true

# The one error shape every non-2xx response uses. `type` tells the client
# whether retrying is sensible; `retriable` says it explicitly.
class ApiError < StandardError
  extend T::Sig

  class Type < T::Enum
    enums do
      CardError = new("card_error")
      InvalidRequest = new("invalid_request")
      ApiErrorType = new("api_error")
      RateLimit = new("rate_limit")
      IdempotencyError = new("idempotency_error")
    end
  end

  sig { returns(Type) }
  attr_reader :type

  sig { returns(Integer) }
  attr_reader :http_status

  sig { returns(String) }
  attr_reader :code

  sig { returns(T.nilable(String)) }
  attr_reader :param

  sig { returns(T::Boolean) }
  attr_reader :retriable

  sig { returns(T::Hash[String, T::Array[String]]) }
  attr_reader :details

  sig do
    params(type: Type, http_status: Integer, code: String, message: String,
           param: T.nilable(String), retriable: T::Boolean,
           details: T::Hash[String, T::Array[String]]).void
  end
  def initialize(type:, http_status:, code:, message:, param: nil, retriable: false, details: {})
    @type = type
    @http_status = http_status
    @code = code
    @param = param
    @retriable = retriable
    @details = details
    super(message)
  end

  sig { params(request_id: String).returns(T::Hash[String, T.untyped]) }
  def to_h(request_id:)
    body = {
      "type" => type.serialize, "code" => code, "message" => message,
      "param" => param, "retriable" => retriable, "request_id" => request_id
    }
    body["details"] = details if details.any?
    { "error" => body }
  end

  # ── Constructors for the common cases ────────────────────────────────────

  sig { params(message: String, param: T.nilable(String), code: String).returns(ApiError) }
  def self.invalid_request(message, param: nil, code: "invalid_request")
    new(type: Type::InvalidRequest, http_status: 400, code: code, message: message, param: param)
  end

  # 422 with EVERY failing field, not the first one.
  sig { params(errors: T::Hash[String, T::Array[String]]).returns(ApiError) }
  def self.validation(errors)
    new(type: Type::InvalidRequest, http_status: 422, code: "validation_failed",
        message: "#{errors.size} field(s) failed validation", param: errors.keys.first, details: errors)
  end

  sig { returns(ApiError) }
  def self.unauthorized
    new(type: Type::InvalidRequest, http_status: 401, code: "unauthorized", message: "Invalid or missing API key")
  end

  sig { params(permission: String).returns(ApiError) }
  def self.forbidden(permission)
    new(type: Type::InvalidRequest, http_status: 403, code: "forbidden",
        message: "Your role does not include #{permission}", param: nil)
  end

  sig { params(resource: String).returns(ApiError) }
  def self.not_found(resource)
    new(type: Type::InvalidRequest, http_status: 404, code: "not_found", message: "No such #{resource}")
  end
end
