# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class SessionsController < BaseController
      extend T::Sig

      include TwoFactorSessionActions

      skip_before_action :require_session!, only: %i[create otp recovery]
      # Signing in needs no permission; step_up and destroy still need a session.
      allow_unauthorized only: %i[create otp recovery step_up destroy]

      private

      sig { returns(T.class_of(MerchantUser)) }
      def principal_scope = MerchantUser

      sig { returns(Symbol) }
      def session_cookie_name = COOKIE

      sig { returns(String) }
      def session_cookie_path = "/dashboard"

      sig { params(user: MerchantUser, session_row: Session).returns(T::Hash[String, T.untyped]) }
      def session_payload(user, session_row) = MePresenter.call(user, session_row)
    end
  end
end
