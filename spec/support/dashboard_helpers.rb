# frozen_string_literal: true

module DashboardHelpers
  # Signs in by creating the session row and the signed cookie directly.
  # The sign-in endpoints themselves are covered in sessions_spec.
  def sign_in_as(user, livemode: true, stepped_up: false)
    session = Session.create!(principal: user, ip: "127.0.0.1", user_agent: "rspec", livemode:,
                              stepped_up_at: stepped_up ? Time.current : nil)
    set_signed_cookie(:_payhub_dashboard, session.id)
    session
  end

  def set_signed_cookie(name, value)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[name] = value
    cookies[name] = jar[name]
  end

  def ui_headers(idempotency_key: SecureRandom.uuid)
    { "Content-Type" => "application/json", "Accept" => "application/json", "Idempotency-Key" => idempotency_key }
  end
end

RSpec.configure { |c| c.include DashboardHelpers, type: :request }
