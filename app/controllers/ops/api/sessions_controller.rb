# typed: true
# frozen_string_literal: true

module Ops
  module Api
    class SessionsController < BaseController
      include TwoFactorSessionActions

      skip_before_action :require_session!, only: %i[create otp recovery]
      # Signing in needs no permission; step_up and destroy still need a session.
      allow_unauthorized only: %i[create otp recovery step_up destroy]

      private

      def principal_scope = Operator
      def session_cookie_name = COOKIE
      def session_cookie_path = "/ops"
      def session_payload(operator, session_row) = OperatorMePresenter.call(operator, session_row)
    end
  end
end
