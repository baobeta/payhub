# typed: true
# frozen_string_literal: true

# The Vue app's view of "who am I". permissions[] drives navigation only;
# the server re-checks every request (design §3).
module MePresenter
  def self.call(user, session)
    merchant = T.must(user.merchant)
    stepped = session.stepped_up_at
    {
      "user" => { "id" => user.id, "email" => user.email, "name" => user.name, "role" => user.role },
      "merchant" => { "id" => merchant.id, "name" => merchant.name },
      "livemode" => session.livemode,
      "stepped_up_until" => stepped && (stepped + Session::STEP_UP_WINDOW).utc.iso8601,
      "permissions" => Permissions.for(:merchant, user.role).to_a.sort
    }
  end
end
