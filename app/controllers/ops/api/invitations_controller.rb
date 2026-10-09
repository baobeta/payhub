# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # Inviting a fellow operator and the first half of enrolling them. The
    # token in the email is the credential for show/accept.
    class InvitationsController < BaseController
      ENROL_COOKIE = :_payhub_ops_enrol
      ENROL_TTL = 15.minutes

      skip_before_action :require_session!, only: %i[show accept]
      requires_permission "ops.operators.manage", only: :create
      allow_unauthorized only: %i[show accept] # the token is the credential

      def create
        operator = InviteOperator.call(email: params.require(:email), role: params.require(:role).to_s,
                                       invited_by: current_user)
        audit!("operator.invited", target: operator, metadata: { "email" => operator.email, "role" => operator.role })
        render json: { "id" => operator.id, "email" => operator.email, "role" => operator.role }, status: :created
      end

      def show
        operator = invitation!
        render json: { "email" => operator.email, "role" => operator.role }
      end

      def accept
        operator = invitation!
        operator.update!(name: params.require(:name).to_s, password: params.require(:password).to_s)
        cookies.encrypted[ENROL_COOKIE] = { value: { "id" => operator.id, "exp" => ENROL_TTL.from_now.to_i },
                                            httponly: true, same_site: :strict, secure: Rails.env.production?,
                                            path: "/ops" }
        render json: { "next" => "enrol_otp" }
      end

      private

      def invitation!
        Operator.find_by_invitation_token(params[:token].to_s) || raise(ActiveRecord::RecordNotFound)
      end
    end
  end
end
