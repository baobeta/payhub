# typed: true

# Methods a concern calls but its including class provides. Declared here, not
# in the concern, because a stub in the module would sit in front of a
# superclass's real method at runtime (render_api_error lives on
# Web::BaseController, above the class that includes the concern).

module IdempotentAction
  sig { returns(Merchant) }
  def current_merchant; end

  sig { params(error: ApiError).void }
  def render_api_error(error); end
end

module Authorization
  sig { params(action: String, target: T.untyped, result: String, metadata: T::Hash[String, T.untyped]).void }
  def audit!(action, target: nil, result: "success", metadata: {}); end
end

module Authorization::ClassMethods
  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def authorization_rules; end

  sig { params(value: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def authorization_rules=(value); end
end

module TwoFactorSessionActions
  sig { returns(T.any(T.class_of(MerchantUser), T.class_of(Operator))) }
  def principal_scope; end

  sig { returns(Symbol) }
  def session_cookie_name; end

  sig { returns(String) }
  def session_cookie_path; end

  sig { params(principal: T.any(MerchantUser, Operator), session_row: Session).returns(T::Hash[String, T.untyped]) }
  def session_payload(principal, session_row); end

  sig { params(session_row: Session).void }
  def set_session_cookie(session_row); end

  sig do
    params(action: String, target: T.untyped, result: String, metadata: T::Hash[String, T.untyped]).returns(AuditEvent)
  end
  def audit!(action, target: nil, result: "success", metadata: {}); end

  sig { returns(T.any(MerchantUser, Operator)) }
  def current_user; end

  sig { returns(Session) }
  def current_session; end
end

module SessionListActions
  sig { returns(ActiveSupport::Duration) }
  def idle_timeout; end

  sig do
    params(action: String, target: T.untyped, result: String, metadata: T::Hash[String, T.untyped]).returns(AuditEvent)
  end
  def audit!(action, target: nil, result: "success", metadata: {}); end

  sig { returns(T.any(MerchantUser, Operator)) }
  def current_user; end

  sig { returns(Session) }
  def current_session; end
end

# Columns and has_many associations shared by MerchantUser and Operator.
module TwoFactorPrincipal
  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def disabled_at; end

  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def otp_enabled_at; end

  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def locked_until; end

  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def accepted_at; end

  sig { returns(Integer) }
  def failed_attempts; end

  sig { returns(T.nilable(String)) }
  def otp_secret; end

  sig { returns(T.nilable(Integer)) }
  def otp_last_used_step; end

  sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def otp_last_used_step=(value); end

  sig { returns(Session::PrivateCollectionProxy) }
  def sessions; end
end
