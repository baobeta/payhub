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
    layout "web"

    rescue_from ApiError, with: :render_api_error

    private

    sig { params(error: ApiError).void }
    def render_api_error(error)
      render json: error.to_h(request_id: request.request_id.to_s), status: error.http_status
    end
  end
end
