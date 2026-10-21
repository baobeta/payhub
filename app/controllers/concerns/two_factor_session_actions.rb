# typed: true
# frozen_string_literal: true

# Password → TOTP (or recovery code) → session, plus step-up and sign-out.
# The including controller defines principal_scope, session_cookie_name,
# session_cookie_path and session_payload, and gets set_session_cookie and
# audit! from its area base controller. Those methods are declared in
# sorbet/rbi/shims/concerns.rbi.
module TwoFactorSessionActions
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::Base }

  PENDING_TTL = 5.minutes
  ENROL_TTL = 15.minutes # as long as an invitation's enrol step

  sig { void }
  def create
    email = params.require(:email).to_s
    result = SignIn.password(principal_scope, email:, password: params.require(:password))
    unless result.status == :ok
      audit_auth_failure(result.principal, factor: "password", just_locked: result.just_locked, email:)
      raise ApiError.locked(result.principal&.locked_until || SignIn::LOCKED_FALLBACK.from_now) if result.status == :locked

      raise ApiError.unauthenticated(code: "invalid_credentials", message: "Email or password is wrong")
    end
    return start_enrolment(result.principal) unless result.principal.otp_enabled?

    cookies.encrypted[pending_cookie] = { value: { "id" => result.principal.id, "exp" => PENDING_TTL.from_now.to_i },
                                          httponly: true, same_site: :strict, secure: Rails.env.production?,
                                          path: session_cookie_path }
    render json: { otp_required: true }
  end

  sig { void }
  def otp = second_factor { |principal| principal.verify_otp!(params.require(:code)) }
  # NIST 800-63B §4.2: using a recovery code is worth telling the person about.
  sig { void }
  def recovery
    second_factor { |principal| RecoveryCode.consume!(principal, params.require(:code)) }
    SecurityMailer.recovery_code_used(current_user).deliver_later
  end

  # Step-up guards a live session; a stolen cookie must not get unlimited
  # guesses. Ten wrong codes lock the account and end every session.
  sig { void }
  def step_up
    raise ApiError.locked(T.must(current_user.locked_until)) if current_user.locked?

    unless current_user.verify_otp!(params.require(:code))
      just_locked = current_user.register_failure!
      audit_auth_failure(current_user, factor: "step_up", just_locked:)
      current_user.revoke_sessions! if just_locked
      raise ApiError.unauthenticated(code: "invalid_code", message: "That code is not valid")
    end
    current_session.step_up!
    audit!("session.stepped_up")
    render json: { stepped_up_until: (T.must(current_session.stepped_up_at) + Session::STEP_UP_WINDOW).utc.iso8601 }
  end

  sig { void }
  def destroy
    current_session.revoke!
    audit!("session.revoked")
    cookies.delete(session_cookie_name, path: session_cookie_path)
    head :no_content
  end

  private

  sig { returns(Symbol) }
  def pending_cookie = :"#{session_cookie_name}_2fa"

  # M12: an admin reset this person's authenticator (Stripe's 2FA recovery).
  # The password proved who they are; still no session until they enrol a
  # new authenticator, through the same enrol cookie and otp/setup + confirm
  # steps as accepting an invitation (InvitationsController::ENROL_COOKIE is
  # "<session cookie>_enrol" in both areas).
  sig { params(principal: T.any(MerchantUser, Operator)).void }
  def start_enrolment(principal)
    cookies.encrypted[:"#{session_cookie_name}_enrol"] = {
      value: { "id" => principal.id, "exp" => ENROL_TTL.from_now.to_i },
      httponly: true, same_site: :strict, secure: Rails.env.production?, path: session_cookie_path
    }
    render json: { "next" => "enrol_otp" }
  end

  sig { returns(T.nilable(T.any(MerchantUser, Operator))) }
  def pending_principal
    data = cookies.encrypted[pending_cookie]
    return nil unless data.is_a?(Hash) && data["exp"].to_i > Time.current.to_i

    principal_scope.active.find_by(id: data["id"])
  end

  sig { params(blk: T.proc.params(principal: T.any(MerchantUser, Operator)).returns(T::Boolean)).void }
  def second_factor(&blk)
    principal = pending_principal
    raise ApiError.unauthenticated(code: "password_step_required", message: "Enter your password first") unless principal
    raise ApiError.locked(T.must(principal.locked_until)) if principal.locked?

    unless yield(principal)
      audit_auth_failure(principal, factor: action_name, just_locked: principal.register_failure!)
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

  # PCI DSS 10.2.1.4: invalid access attempts are logged. Against the
  # principal's merchant when the account exists, so the merchant's security
  # history shows someone guessing.
  sig do
    params(principal: T.nilable(T.any(MerchantUser, Operator)), factor: String, just_locked: T.nilable(T::Boolean),
           email: T.nilable(String)).void
  end
  def audit_auth_failure(principal, factor:, just_locked:, email: nil)
    @refusal_audited = true # this row is the audit of the refusal (Authorization#audit_refusal)
    Metrics.increment(:auth_failed, area: session_cookie_path.delete_prefix("/"), factor:)
    context = { actor: principal, actor_label: principal&.email || email.to_s.first(254),
                merchant_id: principal.try(:merchant_id), ip: request.remote_ip,
                user_agent: request.user_agent, request_id: request.request_id }
    AuditEvent.record!(action: "session.failed", result: "failure", metadata: { "factor" => factor }, **context)
    return unless just_locked && principal

    AuditEvent.record!(action: "account.locked", result: "denied", metadata: { "factor" => factor }, **context)
    SecurityMailer.account_locked(principal, until_at: T.must(principal.locked_until)).deliver_later
  end

  sig { params(principal: T.any(MerchantUser, Operator), session_row: Session).void }
  def notify_if_new_device(principal, session_row)
    earlier = principal.sessions.where.not(id: session_row.id)
    return unless earlier.exists?
    return if earlier.exists?(ip: session_row.ip, user_agent: session_row.user_agent)

    SecurityMailer.new_sign_in(principal, ip: session_row.ip, user_agent: session_row.user_agent).deliver_later
  end
end
