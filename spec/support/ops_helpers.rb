# frozen_string_literal: true

module OpsHelpers
  # Signs an operator in by creating the session row and signed cookie directly.
  # The sign-in endpoints themselves are covered in ops/api/sessions_spec.
  def sign_in_operator(operator, stepped_up: false)
    session = Session.create!(principal: operator, ip: "127.0.0.1", user_agent: "rspec",
                              stepped_up_at: stepped_up ? Time.current : nil)
    set_signed_cookie(:_payhub_ops, session.id)
    session
  end
end

RSpec.configure { |c| c.include OpsHelpers, type: :request }
