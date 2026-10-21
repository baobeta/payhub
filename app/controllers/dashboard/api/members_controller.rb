# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-19, M-20. Members belong to the live merchant whatever the mode.
    class MembersController < BaseController
      extend T::Sig

      requires_permission "team.read", only: :index
      requires_permission "team.manage", only: %i[update destroy reset_otp]

      rescue_from ChangeMemberRole::Refused do |e|
        T.bind(self, Dashboard::Api::MembersController)
        render_api_error(ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused",
                                      message: e.message))
      end

      sig { void }
      def index
        render json: { "data" => live_merchant.merchant_users.order(:created_at).map { |u| MemberSerializer.call(u) } }
      end

      sig { void }
      def update
        member = live_merchant.merchant_users.find(params[:id])
        from = member.role
        ChangeMemberRole.call(actor: current_user, member:, role: params.require(:role).to_s)
        audit!("team.role_changed", target: member, metadata: { "email" => member.email, "from" => from, "to" => member.role })
        notify_owner("team.role_changed", detail: "#{member.email}: #{from} → #{member.role}")
        render json: MemberSerializer.call(member)
      end

      sig { void }
      def destroy
        member = live_merchant.merchant_users.find(params[:id])
        ChangeMemberRole.remove(actor: current_user, member:)
        audit!("team.removed", target: member, metadata: { "email" => member.email })
        notify_owner("team.removed", detail: member.email)
        render json: MemberSerializer.call(member)
      end

      # M12: reset a member's lost authenticator (team.manage, step-up).
      sig { void }
      def reset_otp
        member = live_merchant.merchant_users.find(params[:id])
        _, token = ChangeMemberRole.reset_otp(actor: current_user, member:)
        audit!("team.otp_reset", target: member, metadata: { "email" => member.email })
        SecurityMailer.otp_reset(member, token).deliver_later
        notify_owner("team.otp_reset", detail: member.email)
        render json: MemberSerializer.call(member)
      end
    end
  end
end
