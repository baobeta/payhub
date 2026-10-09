# typed: true
# frozen_string_literal: true

# The ops Vue app's view of "who am I". permissions[] drives navigation only;
# the server re-checks every request (design §3). A merchant has no ops
# permission, and an operator has no merchant, so this payload never carries
# a merchant except while impersonating.
module OperatorMePresenter
  def self.call(operator, session)
    stepped = session.stepped_up_at
    {
      "user" => { "id" => operator.id, "email" => operator.email, "name" => operator.name, "role" => operator.role },
      "stepped_up_until" => stepped && (stepped + Session::STEP_UP_WINDOW).utc.iso8601,
      "permissions" => Permissions.for(:operator, operator.role).to_a.sort,
      "impersonating" => impersonating(session)
    }
  end

  def self.impersonating(session)
    return nil unless session.impersonating?

    merchant = Merchant.find_by(id: session.impersonating_merchant_id)
    {
      "merchant_id" => session.impersonating_merchant_id,
      "merchant_name" => merchant&.name,
      "case_ref" => session.impersonation_case_ref,
      "expires_at" => session.impersonation_expires_at&.utc&.iso8601
    }
  end
end
