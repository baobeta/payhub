# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class SessionsController < BaseController
      include TwoFactorSessionActions

      skip_before_action :require_session!, only: %i[create otp recovery]
      # Signing in needs no permission; step_up and destroy still need a session.
      allow_unauthorized only: %i[create otp recovery step_up destroy]

      private

      def principal_scope = MerchantUser
      def session_cookie_name = COOKIE
      def session_cookie_path = "/dashboard"
      def session_payload(user, session_row) = MePresenter.call(user, session_row)
    end
  end
end
