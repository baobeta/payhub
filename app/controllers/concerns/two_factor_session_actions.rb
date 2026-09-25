# typed: false
# frozen_string_literal: true

# Password → TOTP (or recovery code) → session, plus step-up and sign-out.
# The including controller defines principal_scope, session_cookie_name,
# session_cookie_path and session_payload, and gets set_session_cookie and
# audit! from its area base controller.
# typed: false: uses the controller API (cookies, params, render).
module TwoFactorSessionActions
  extend ActiveSupport::Concern

  PENDING_TTL = 5.minutes

  def create
    result = SignIn.password(principal_scope, email: params.require(:email), password: params.require(:password))
    case result.status
    when :locked then raise ApiError.locked(result.principal&.locked_until || SignIn::LOCKED_FALLBACK.from_now)
    when :invalid then raise ApiError.unauthenticated(code: "invalid_credentials", message: "Email or password is wrong")
    end

    cookies.encrypted[pending_cookie] = { value: { "id" => result.principal.id, "exp" => PENDING_TTL.from_now.to_i },
                                          httponly: true, same_site: :strict, secure: Rails.env.production?,
                                          path: session_cookie_path }
    render json: { otp_required: true }
  end

  def otp = second_factor { |principal| principal.verify_otp!(params.require(:code)) }
  def recovery = second_factor { |principal| RecoveryCode.consume!(principal, params.require(:code)) }

  def step_up
    unless current_user.verify_otp!(params.require(:code))
      current_user.register_failure!
      raise ApiError.unauthenticated(code: "invalid_code", message: "That code is not valid")
    end
    current_session.step_up!
    audit!("session.stepped_up")
    render json: { stepped_up_until: (current_session.stepped_up_at + Session::STEP_UP_WINDOW).utc.iso8601 }
  end

  def destroy
    current_session.revoke!
    audit!("session.revoked")
    cookies.delete(session_cookie_name, path: session_cookie_path)
    head :no_content
  end

  private

  def pending_cookie = :"#{session_cookie_name}_2fa"

  def pending_principal
    data = cookies.encrypted[pending_cookie]
    return nil unless data.is_a?(Hash) && data["exp"].to_i > Time.current.to_i

    principal_scope.active.find_by(id: data["id"])
  end

  def second_factor
    principal = pending_principal
    raise ApiError.unauthenticated(code: "password_step_required", message: "Enter your password first") unless principal
    raise ApiError.locked(principal.locked_until) if principal.locked?

    unless yield(principal)
      principal.register_failure!
      raise ApiError.unauthenticated(code: "invalid_code", message: "That code is not valid")
    end

    principal.reset_failures!
    session_row = Session.create!(principal:, ip: request.remote_ip, user_agent: request.user_agent)
    notify_if_new_device(principal, session_row)
    cookies.delete(pending_cookie, path: session_cookie_path)
    set_session_cookie(session_row)
    @current_session = session_row
    @current_user = principal
    audit!("session.created")
    render json: session_payload(principal, session_row)
  end

  def notify_if_new_device(principal, session_row)
    earlier = principal.sessions.where.not(id: session_row.id)
    return unless earlier.exists?
    return if earlier.exists?(ip: session_row.ip, user_agent: session_row.user_agent)

    SecurityMailer.new_sign_in(principal, ip: session_row.ip, user_agent: session_row.user_agent).deliver_later
  end
end
