# typed: true
# frozen_string_literal: true

module Ops
  module Api
    class SessionsController < BaseController
      extend T::Sig

      include TwoFactorSessionActions

      skip_before_action :require_session!, only: %i[create otp recovery]
      # Signing in needs no permission; step_up and destroy still need a session.
      allow_unauthorized only: %i[create otp recovery step_up destroy]

      private

      sig { returns(T.class_of(Operator)) }
      def principal_scope = Operator

      sig { returns(Symbol) }
      def session_cookie_name = COOKIE

      sig { returns(String) }
      def session_cookie_path = "/ops"

      sig { params(operator: Operator, session_row: Session).returns(T::Hash[String, T.untyped]) }
      def session_payload(operator, session_row) = OperatorMePresenter.call(operator, session_row)
    end
  end
end
