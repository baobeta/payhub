# typed: true
# frozen_string_literal: true

module Web
  # Base for every UI controller (/dashboard, /ops, /demo). Unlike /v1 it has
  # cookies, CSRF protection and HTML layouts. Authorization is declared per
  # action; see Authorization and design §3.
  class BaseController < ActionController::Base
    extend T::Sig
    include Authorization

    protect_from_forgery with: :exception
    before_action do
      T.bind(self, Web::BaseController)
      Current.request_id = request.request_id
    end
    layout "web"

    rescue_from ApiError, with: :render_api_error
    rescue_from ActionController::InvalidAuthenticityToken do
      T.bind(self, Web::BaseController)
      render_api_error(ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 403, code: "invalid_csrf_token",
                                    message: "Reload the page and try again"))
    end

    private

    # Picked up by lograge's custom_payload. Never params: they can hold secrets.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def log_payload
      { request_id: request.request_id, merchant_id: try(:authorization_merchant_id),
        skip_request_log: @skip_request_log }.compact
    end

    sig { params(error: ApiError).void }
    def render_api_error(error)
      render json: error.to_h(request_id: request.request_id.to_s), status: error.http_status
    end
  end
end
