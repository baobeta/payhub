# typed: true
# frozen_string_literal: true

# M-21. Demote first, then promote: the one-owner partial unique index would
# refuse the other order.
module TransferOwnership
  extend T::Sig

  class Refused < StandardError; end

  sig { params(owner: MerchantUser, to: MerchantUser).void }
  def self.call(owner:, to:)
    raise Refused, "Choose another active, enrolled team member" if to.id == owner.id || !to.active? || !to.otp_enabled?
    raise Refused, "Both people must belong to the same account" unless to.merchant_id == owner.merchant_id

    MerchantUser.transaction do
      owner.update!(role: "admin")
      to.update!(role: "owner")
    end
  end
end
