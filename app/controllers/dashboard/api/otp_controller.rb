# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # Enrolment right after accepting an invitation. The short-lived encrypted
    # enrol cookie, set by InvitationsController#accept, is the credential.
    class OtpController < BaseController
      skip_before_action :require_session!
      allow_unauthorized only: %i[setup confirm]

      def setup
        user = enrolling_user!
        uri = Otp.provisioning_uri(T.must(user.otp_secret), user.email)
        render json: { "provisioning_uri" => uri, "qr_svg" => Otp.qr_svg(uri) }
      end

      # accepted_at is set only here, so a half-enrolled user cannot sign in
      # (SignIn requires accepted_at).
      def confirm
        user = enrolling_user!
        unless user.verify_otp!(params.require(:code))
          raise ApiError.unauthenticated(code: "invalid_code", message: "That code is not valid")
        end

        user.update!(otp_enabled_at: Time.current, accepted_at: Time.current, invitation_digest: nil)
        codes = RecoveryCode.regenerate!(user)
        session_row = Session.create!(principal: user, ip: request.remote_ip, user_agent: request.user_agent)
        cookies.delete(InvitationsController::ENROL_COOKIE, path: "/dashboard")
        set_session_cookie(session_row)
        @current_session = session_row
        @current_user = user
        audit!("user.enrolled", target: user)
        render json: MePresenter.call(user, session_row).merge("recovery_codes" => codes)
      end

      private

      def enrolling_user!
        data = cookies.encrypted[InvitationsController::ENROL_COOKIE]
        unless data.is_a?(Hash) && data["exp"].to_i > Time.current.to_i
          raise ApiError.unauthenticated(code: "enrolment_expired", message: "Open your invitation link again")
        end

        MerchantUser.active.where(otp_enabled_at: nil).find_by(id: data["id"]) || raise(ApiError.unauthenticated)
      end
    end
  end
end
