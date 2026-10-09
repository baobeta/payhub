# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-21: only the owner, only to an enrolled member of the same account.
    class OwnershipTransfersController < BaseController
      requires_permission "ownership.transfer", only: :create

      def create
        to = live_merchant.merchant_users.find(params.require(:member_id))
        owner = current_user
        TransferOwnership.call(owner:, to:)
        audit!("team.ownership_transferred", target: to, metadata: { "from" => owner.email, "to" => to.email })
        [owner, to].each do |person|
          SecurityMailer.ownership_transferred(person, from: owner.email, to: to.email).deliver_later
        end
        render json: MemberSerializer.call(to.reload)
      rescue TransferOwnership::Refused => e
        raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused", message: e.message)
      end
    end
  end
end
