# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class InvitationsController < BaseController
      ENROL_COOKIE = :_payhub_dashboard_enrol
      ENROL_TTL = 15.minutes

      skip_before_action :require_session!, only: %i[show accept]
      requires_permission "team.manage", only: :create
      allow_unauthorized only: %i[show accept] # the token is the credential

      def create
        role = params.require(:role).to_s
        unless MerchantUser::INVITABLE_ROLES.include?(role)
          raise ApiError.validation("role" => ["must be one of #{MerchantUser::INVITABLE_ROLES.join(', ')}"])
        end

        user, token = MerchantUser.invite!(merchant: live_merchant, email: params.require(:email).to_s, role:,
                                           invited_by: current_user)
        InvitationMailer.invite(user, token).deliver_later
        audit!("team.invited", target: user, metadata: { "email" => user.email, "role" => role })
        render json: MemberSerializer.call(user), status: :created
      rescue ActiveRecord::RecordNotUnique
        raise ApiError.validation("email" => ["already belongs to a PayHub user"])
      end

      def show
        user = invitation!
        render json: { "email" => user.email, "role" => user.role, "merchant_name" => T.must(user.merchant).name }
      end

      def accept
        user = invitation!
        user.update!(name: params.require(:name).to_s, password: params.require(:password).to_s)
        cookies.encrypted[ENROL_COOKIE] = { value: { "id" => user.id, "exp" => ENROL_TTL.from_now.to_i },
                                            httponly: true, same_site: :strict, secure: Rails.env.production?,
                                            path: "/dashboard" }
        render json: { "next" => "enrol_otp" }
      rescue ActiveRecord::RecordInvalid => e
        raise ApiError.validation(e.record.errors.to_hash.transform_keys(&:to_s))
      end

      private

      def invitation!
        MerchantUser.find_by_invitation_token(params[:token].to_s) || raise(ActiveRecord::RecordNotFound)
      end
    end
  end
end
