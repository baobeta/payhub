# typed: true
# frozen_string_literal: true

module V1
  class BaseController < ApplicationController
    extend T::Sig

    before_action :authenticate_merchant!
    before_action :require_idempotency_key!, if: -> {
      T.bind(self, V1::BaseController)
      request.post?
    }
    around_action :with_idempotency, if: -> {
      T.bind(self, V1::BaseController)
      request.post?
    }

    rescue_from ApiError, with: :render_api_error
    rescue_from ActiveRecord::RecordNotFound do
      T.bind(self, V1::BaseController)
      render_api_error(ApiError.not_found("resource"))
    end
    rescue_from ActionController::ParameterMissing do |e|
      T.bind(self, V1::BaseController)
      render_api_error(ApiError.invalid_request("Missing parameter: #{e.param}", param: e.param.to_s))
    end
    # A currency we route but cannot price, or cannot route at all. The
    # request is well-formed; our configuration is not. api_error + retriable,
    # because an operator can fix it without the merchant changing anything.
    rescue_from FxRate::Missing, PspRouter::NoRoute do |e|
      T.bind(self, V1::BaseController)
      render_api_error(ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 503, code: "currency_unavailable",
                                    message: e.message, param: "currency", retriable: true))
    end

    private

    sig { returns(Merchant) }
    def current_merchant = T.must(@current_merchant)

    sig { void }
    def authenticate_merchant!
      raw = request.authorization.to_s.delete_prefix("Bearer ").strip
      @current_merchant = T.let(Merchant.authenticate(raw), T.nilable(Merchant))
      raise ApiError.unauthorized unless @current_merchant
    end

    # Every POST needs one. The key's semantics (claim, replay, 409) come in
    # Phase 4; for now we only enforce presence, as the contract requires.
    sig { void }
    def require_idempotency_key!
      return if request.headers["Idempotency-Key"].present?

      raise ApiError.invalid_request("Idempotency-Key header is required", param: "Idempotency-Key",
                                                                          code: "missing_idempotency_key")
    end

    # Runs the action at most once per (merchant, Idempotency-Key). The action
    # renders inside the guard so its status and body — including 4xx errors,
    # which are legitimate repeatable answers — are memoised. 5xx and raised
    # exceptions release the claim (see IdempotencyGuard#run).
    sig { params(action: T.proc.void).void }
    def with_idempotency(&action)
      guard = IdempotencyGuard.new(
        merchant: current_merchant, key: request.headers["Idempotency-Key"].to_s,
        request_method: request.request_method, path: request.path, raw_body: request.raw_post
      )

      outcome = guard.call do
        begin
          action.call
        rescue ApiError => e
          # rescue_from runs outside around_action; catch here so the error
          # response is what gets stored and replayed.
          render_api_error(e)
        end
        [response.status, JSON.parse(response.body)]
      end

      return unless outcome.replayed

      response.set_header("Idempotent-Replayed", "true")
      render json: outcome.body, status: outcome.status
    end

    sig { params(error: ApiError).void }
    def render_api_error(error)
      render json: error.to_h(request_id: request.request_id.to_s), status: error.http_status
    end
  end
end
