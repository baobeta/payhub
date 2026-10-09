# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # Every /ops/api controller. Operators are PayHub staff: a separate cookie,
    # a shorter idle timeout than merchants, and a role that a merchant can
    # never grant. Layer order (design §3): session (401), permission (403),
    # step-up (401 step_up_required), record rules in services (409/422).
    class BaseController < Web::BaseController
      COOKIE = :_payhub_ops
      IDLE_TIMEOUT = 10.minutes

      wrap_parameters false
      before_action :require_session!

      rescue_from ActiveRecord::RecordNotFound do
        T.bind(self, Ops::Api::BaseController)
        render_api_error(ApiError.not_found("resource"))
      end
      rescue_from ActiveRecord::RecordInvalid do |e|
        T.bind(self, Ops::Api::BaseController)
        render_api_error(ApiError.validation(e.record.errors.to_hash.transform_keys(&:to_s)))
      end
      rescue_from ActionController::ParameterMissing do |e|
        T.bind(self, Ops::Api::BaseController)
        render_api_error(ApiError.invalid_request("Missing parameter: #{e.param}", param: e.param.to_s))
      end
      rescue_from PspAdapter::Unavailable, PspAdapter::TimedOut do |e|
        T.bind(self, Ops::Api::BaseController)
        render_api_error(ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 503, code: "psp_unavailable",
                                      message: e.message, retriable: true))
      end

      private

      def require_session!
        row = Session.find_by(id: cookies.signed[COOKIE], principal_type: "Operator")
        operator = row&.principal
        raise ApiError.unauthenticated unless row&.active?(idle: IDLE_TIMEOUT) && operator.is_a?(Operator) && operator.active?

        @current_session = T.let(row, T.nilable(Session))
        @current_user = T.let(operator, T.nilable(Operator))
        row.touch_activity! unless request.headers["X-Poll"] == "1"
      end

      def current_session = T.must(@current_session)
      def current_user = T.must(@current_user)

      def authorization_area = :operator
      def authorization_role = @current_user&.role
      def authorization_actor = @current_user
      def step_up_fresh? = @current_session&.stepped_up? || false

      # An operator acting on a merchant's data is recorded against that
      # merchant as well as on behalf of them (design §9).
      def audit!(action, target: nil, merchant_id: nil, on_behalf_of_merchant_id: nil, result: "success", metadata: {})
        AuditEvent.record!(
          action:, result:, actor: current_user, actor_label: current_user.email,
          merchant_id:, on_behalf_of_merchant_id:, target:, ip: request.remote_ip,
          user_agent: request.user_agent, request_id: request.request_id, metadata:
        )
      end

      def set_session_cookie(session_row)
        cookies.signed[COOKIE] = { value: session_row.id, httponly: true, same_site: :strict,
                                   secure: Rails.env.production?, path: "/ops" }
      end
    end
  end
end
