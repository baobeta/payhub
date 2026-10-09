# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # Enrolment right after accepting an invitation. The short-lived encrypted
    # enrol cookie, set by InvitationsController#accept, is the credential.
    class OtpController < BaseController
      skip_before_action :require_session!
      allow_unauthorized only: %i[setup confirm]

      def setup
        operator = enrolling_operator!
        uri = Otp.provisioning_uri(T.must(operator.otp_secret), operator.email)
        render json: { "provisioning_uri" => uri, "qr_svg" => Otp.qr_svg(uri) }
      end

      # accepted_at is set only here, so a half-enrolled operator cannot sign in
      # (SignIn requires accepted_at).
      def confirm
        operator = enrolling_operator!
        unless operator.verify_otp!(params.require(:code))
          raise ApiError.unauthenticated(code: "invalid_code", message: "That code is not valid")
        end

        operator.update!(otp_enabled_at: Time.current, accepted_at: Time.current, invitation_digest: nil)
        codes = RecoveryCode.regenerate!(operator)
        session_row = Session.create!(principal: operator, ip: request.remote_ip, user_agent: request.user_agent)
        cookies.delete(InvitationsController::ENROL_COOKIE, path: "/ops")
        set_session_cookie(session_row)
        @current_session = session_row
        @current_user = operator
        audit!("operator.enrolled", target: operator)
        render json: OperatorMePresenter.call(operator, session_row).merge("recovery_codes" => codes)
      end

      private

      def enrolling_operator!
        data = cookies.encrypted[InvitationsController::ENROL_COOKIE]
        unless data.is_a?(Hash) && data["exp"].to_i > Time.current.to_i
          raise ApiError.unauthenticated(code: "enrolment_expired", message: "Open your invitation link again")
        end

        Operator.active.where(otp_enabled_at: nil).find_by(id: data["id"]) || raise(ApiError.unauthenticated)
      end
    end
  end
end
