# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class MeController < BaseController
      # Any signed-in user: no permission needed, but require_session! still runs.
      # Changing credentials is sensitive even though no permission names it.
      before_action :require_step_up!, only: %i[password recovery_codes]
      allow_unauthorized only: %i[show password recovery_codes]

      def show = render(json: MePresenter.call(current_user, current_session))

      def password
        unless current_user.authenticate(params.require(:current_password).to_s)
          raise ApiError.validation("current_password" => ["is wrong"])
        end

        current_user.update!(password: params.require(:new_password).to_s)
        current_user.sessions.where.not(id: current_session.id).where(revoked_at: nil)
                    .update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        audit!("user.password_changed")
        head :no_content
      end

      def recovery_codes
        codes = RecoveryCode.regenerate!(current_user)
        audit!("user.recovery_codes_regenerated")
        render json: { "recovery_codes" => codes }
      end

      private

      def require_step_up! = (raise ApiError.step_up_required unless current_session.stepped_up?)
    end
  end
end
