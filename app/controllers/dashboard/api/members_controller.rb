# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-19, M-20. Members belong to the live merchant whatever the mode.
    class MembersController < BaseController
      requires_permission "team.read", only: :index
      requires_permission "team.manage", only: %i[update destroy]

      rescue_from ChangeMemberRole::Refused do |e|
        T.bind(self, Dashboard::Api::MembersController)
        render_api_error(ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused",
                                      message: e.message))
      end

      def index
        render json: { "data" => live_merchant.merchant_users.order(:created_at).map { |u| MemberSerializer.call(u) } }
      end

      def update
        member = live_merchant.merchant_users.find(params[:id])
        from = member.role
        ChangeMemberRole.call(actor: current_user, member:, role: params.require(:role).to_s)
        audit!("team.role_changed", target: member, metadata: { "email" => member.email, "from" => from, "to" => member.role })
        render json: MemberSerializer.call(member)
      end

      def destroy
        member = live_merchant.merchant_users.find(params[:id])
        ChangeMemberRole.remove(actor: current_user, member:)
        audit!("team.removed", target: member, metadata: { "email" => member.email })
        render json: MemberSerializer.call(member)
      end
    end
  end
end
