# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # Every /dashboard/api controller. Layer order (design §3): session (401),
    # tenant scoping via current_merchant (404), permission (403), record
    # rules in services (409/422), step-up (401 step_up_required).
    class BaseController < Web::BaseController
      include IdempotentAction
      include ImpersonationContext

      COOKIE = :_payhub_dashboard
      IDLE_TIMEOUT = 15.minutes

      wrap_parameters false
      before_action :require_session!

      rescue_from ActiveRecord::RecordNotFound do
        T.bind(self, Dashboard::Api::BaseController)
        Metrics.increment(:tenant_not_found, area: "merchant")
        render_api_error(ApiError.not_found("resource"))
      end
      rescue_from ActiveRecord::RecordInvalid do |e|
        T.bind(self, Dashboard::Api::BaseController)
        render_api_error(ApiError.validation(e.record.errors.to_hash.transform_keys(&:to_s)))
      end
      rescue_from ActionController::ParameterMissing do |e|
        T.bind(self, Dashboard::Api::BaseController)
        render_api_error(ApiError.invalid_request("Missing parameter: #{e.param}", param: e.param.to_s))
      end
      rescue_from PspAdapter::Unavailable, PspAdapter::TimedOut do |e|
        T.bind(self, Dashboard::Api::BaseController)
        render_api_error(ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 503, code: "psp_unavailable",
                                      message: e.message, retriable: true))
      end

      private

      def require_session!
        return require_impersonation_session! if impersonating_request?

        row = Session.find_by(id: cookies.signed[COOKIE], principal_type: "MerchantUser")
        user = row&.principal
        raise ApiError.unauthenticated unless row&.active?(idle: IDLE_TIMEOUT) && user.is_a?(MerchantUser) && user.active?

        @current_session = T.let(row, T.nilable(Session))
        @current_user = T.let(user, T.nilable(MerchantUser))
        # A page refreshing itself is not the person being active; otherwise an
        # open payment page would defeat the idle timeout (PCI 8.2.8).
        row.touch_activity! unless request.headers["X-Poll"] == "1"
      end

      def current_session = T.must(@current_session)
      def current_user = T.must(@current_user)
      def live_merchant = impersonating_request? ? T.must(@impersonated_merchant) : T.must(current_user.merchant)

      # Tenant scoping (layer 2): every query starts here. Impersonation always
      # shows the live merchant.
      def current_merchant
        return live_merchant if impersonating_request?

        current_session.livemode ? live_merchant : live_merchant.test_twin!
      end

      def authorization_area = :merchant
      def authorization_role = impersonating_request? ? "impersonation" : @current_user&.role
      def authorization_actor = impersonating_request? ? @impersonator : @current_user
      def authorization_merchant_id
        impersonating_request? ? @impersonated_merchant&.id : @current_user&.merchant_id
      end
      def step_up_fresh? = @current_session&.stepped_up? || false

      # Security history rows always belong to the LIVE merchant.
      def audit!(action, target: nil, result: "success", metadata: {})
        if impersonating_request?
          return AuditEvent.record!(
            action:, result:, actor: @impersonator, actor_label: "#{T.must(@impersonator).email} (PayHub support)",
            merchant_id: nil, on_behalf_of_merchant_id: T.must(@impersonated_merchant).id, target:,
            ip: request.remote_ip, user_agent: request.user_agent, request_id: request.request_id,
            metadata: metadata.merge("impersonation" => true)
          )
        end

        AuditEvent.record!(
          action:, result:, actor: current_user, actor_label: current_user.email, merchant_id: live_merchant.id,
          target:, ip: request.remote_ip, user_agent: request.user_agent, request_id: request.request_id,
          metadata: metadata.merge("livemode" => current_session.livemode)
        )
      end

      def set_session_cookie(session_row)
        cookies.signed[COOKIE] = { value: session_row.id, httponly: true, same_site: :strict,
                                   secure: Rails.env.production?, path: "/dashboard" }
      end
    end
  end
end
