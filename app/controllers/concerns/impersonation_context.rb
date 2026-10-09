# typed: false
# frozen_string_literal: true

# Read-only merchant view for operators (design §4, O-12). Included by
# Dashboard::Api::BaseController; only active for the /ops/api/as/* routes,
# which carry `defaults: { impersonation: "1" }`.
#
# The session is the operator's ops session (the request is under /ops, so the
# ops cookie is sent). Every merchant permission is faked down to `.read`, so
# even a route added under `as/` later cannot write.
module ImpersonationContext
  extend ActiveSupport::Concern

  private

  def impersonating_request? = params[:impersonation].to_s == "1"

  def require_impersonation_session!
    row = Session.find_by(id: cookies.signed[Ops::Api::BaseController::COOKIE], principal_type: "Operator")
    operator = row&.principal
    raise ApiError.unauthenticated unless row&.active?(idle: Ops::Api::BaseController::IDLE_TIMEOUT) &&
                                         operator.is_a?(Operator) && operator.active?

    unless row.impersonating? && row.impersonating_merchant_id.to_s == params[:as_merchant_id].to_s
      raise ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 403, code: "impersonation_expired",
                         message: "This impersonation has ended or targets another merchant")
    end

    @current_session = T.let(row, T.nilable(Session))
    @impersonator = T.let(operator, T.nilable(Operator))
    @impersonated_merchant = T.let(Merchant.find(row.impersonating_merchant_id), T.nilable(Merchant))
    @current_user = nil
  end

  # Read-only: any known merchant permission ending in .read, nothing else,
  # whatever the operator's role (design §3 layer 5).
  def permission_granted?(permission)
    return super unless impersonating_request?

    permission.to_s.end_with?(".read") && Permissions.known?(permission)
  end

  # A write attempt under `as/` is refused with a clearer code than plain 403.
  def record_denial(permission)
    super
    return unless impersonating_request?

    raise ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 403, code: "impersonation_read_only",
                       message: "Impersonation is read-only")
  end
end
