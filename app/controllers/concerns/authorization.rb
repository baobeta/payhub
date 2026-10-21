# typed: true
# frozen_string_literal: true

# Fail-closed authorization for UI controllers (design §3).
#
#   requires_permission "payments.refund", only: :create   # checked BEFORE the action
#   allow_unauthorized only: :show                          # explicit, greppable opt-out
#
# Including controllers implement authorization_area (:merchant / :operator)
# and authorization_role (the signed-in principal's role string). An action
# with neither declaration raises NotDeclared in development and test; the
# route-inventory spec makes that a CI failure before it can reach production.
#
# The class_attribute accessors are declared in sorbet/rbi/shims/concerns.rbi.
# spec/controllers/web/base_controller_authorization_spec.rb covers it.
module Authorization
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::Metal }

  class NotDeclared < StandardError; end

  included do
    class_attribute :authorization_rules, instance_writer: false, default: []
    after_action :verify_authorization_declared
  end

  class_methods do
    extend T::Sig
    extend T::Helpers

    requires_ancestor { Kernel }
    requires_ancestor { AbstractController::Callbacks::ClassMethods }

    sig do
      params(permission: String, only: T.nilable(T.any(Symbol, T::Array[Symbol])),
             except: T.nilable(T.any(Symbol, T::Array[Symbol]))).void
    end
    def requires_permission(permission, only: nil, except: nil)
      raise Permissions::Unknown, "unknown permission #{permission.inspect}" unless Permissions.known?(permission)

      add_authorization_rule(kind: :permission, permission:, only:, except:)
      before_action(**{ only:, except: }.compact) do
        T.bind(self, Authorization)
        authorize!(permission)
      end
    end

    sig do
      params(only: T.nilable(T.any(Symbol, T::Array[Symbol])), except: T.nilable(T.any(Symbol, T::Array[Symbol]))).void
    end
    def allow_unauthorized(only: nil, except: nil)
      add_authorization_rule(kind: :public, permission: nil, only:, except:)
      before_action(**{ only:, except: }.compact) { @authorization_checked = true }
    end

    sig { params(action: T.any(String, Symbol)).returns(T::Boolean) }
    def authorization_declared_for?(action)
      authorization_rules.any? { |rule| rule_applies?(rule, action.to_s) }
    end

    private

    sig do
      params(kind: Symbol, permission: T.nilable(String), only: T.nilable(T.any(Symbol, T::Array[Symbol])),
             except: T.nilable(T.any(Symbol, T::Array[Symbol]))).void
    end
    def add_authorization_rule(kind:, permission:, only:, except:)
      self.authorization_rules = authorization_rules + [{
        kind:, permission:,
        only: only && Array(only).map(&:to_s), except: except && Array(except).map(&:to_s)
      }]
    end

    sig { params(rule: T::Hash[Symbol, T.untyped], action: String).returns(T::Boolean) }
    def rule_applies?(rule, action)
      return false if rule[:only] && !rule[:only].include?(action)
      return false if rule[:except]&.include?(action)

      true
    end
  end

  private

  # Layer order (design §3): no principal → 401 with no audit row (anonymous
  # traffic must not fill an append-only table); no grant → audited 403;
  # sensitive permission without a fresh step-up → 401 step_up_required.
  sig { params(permission: String).void }
  def authorize!(permission)
    @authorization_checked = true
    @authorized_permission = permission
    raise ApiError.unauthenticated if authorization_role.nil?

    unless permission_granted?(permission)
      record_denial(permission)
      raise ApiError.forbidden(permission)
    end
    raise ApiError.step_up_required if Permissions.sensitive?(permission) && !step_up_fresh?
  end

  # Phase 2 narrows this for read-only impersonation.
  sig { params(permission: String).returns(T::Boolean) }
  def permission_granted?(permission)
    Permissions.granted?(authorization_area, T.must(authorization_role), permission)
  rescue ArgumentError => e
    raise if e.is_a?(Permissions::Unknown) # a typo in code is a bug, not a denial

    false # unknown role: deny (and audit), never 500
  end

  sig { params(permission: String).void }
  def record_denial(permission)
    @refusal_audited = true
    Metrics.increment(:authz_denied, area: authorization_area.to_s, permission:)
    AuditEvent.record!(
      action: "authorization.denied", result: "denied",
      actor: authorization_actor, actor_label: authorization_actor.try(:email),
      merchant_id: authorization_merchant_id, ip: request.remote_ip, user_agent: request.user_agent,
      request_id: request.request_id,
      metadata: { "permission" => permission, "role" => authorization_role,
                  "route" => "#{controller_path}##{action_name}" }
    )
  end

  # PCI DSS 10.2.1: a signed-in person's refused write is evidence too (a
  # support user trying to over-refund, a missing step-up). Called by the
  # area base controllers as the error is rendered. One row per request, as
  # the permission the action needs (or its route), with the error code and
  # status only: never the request body. Skipped for reads, for anonymous
  # traffic (an append-only table must not fill with it), for plain 401s, and
  # when the refusal was already audited (a 403, a wrong sign-in code).
  sig { params(error: ApiError).void }
  def audit_refusal(error)
    return if @refusal_audited || request.get? || request.head? || authorization_actor.nil?

    step_up = error.code == "step_up_required"
    return if error.http_status == 401 && !step_up

    @refusal_audited = true
    audit!(@authorized_permission || "#{controller_path}##{action_name}",
           result: step_up ? "denied" : "failure",
           metadata: { "code" => error.code, "http_status" => error.http_status })
  rescue StandardError => e
    # The caller must still see the refusal it earned; a lost audit row is
    # loud here, not a 500 that hides why the action was refused.
    Metrics.increment(:audit_write_failed, area: authorization_area.to_s)
    Rails.logger.error({ event: "audit_refusal_failed", route: "#{controller_path}##{action_name}",
                         error: e.class.name, detail: e.message }.to_json)
  end

  sig { void }
  def verify_authorization_declared
    return if @authorization_checked

    Metrics.increment(:authz_undeclared, controller: controller_path)
    message = "#{controller_path}##{action_name} ran without requires_permission or allow_unauthorized"
    raise NotDeclared, message unless Rails.env.production?

    Rails.logger.error({ event: "authorization_undeclared", route: "#{controller_path}##{action_name}" }.to_json)
  end

  # Overridden by the area base controllers in phases 1 and 2.
  sig { returns(Symbol) }
  def authorization_area = raise(NotImplementedError, "#{self.class} must define authorization_area")
  sig { returns(T.nilable(String)) }
  def authorization_role = nil
  sig { returns(T.nilable(T.any(MerchantUser, Operator))) }
  def authorization_actor = nil
  sig { returns(T.nilable(String)) }
  def authorization_merchant_id = nil
  # Fail closed: only an area base controller that tracks step-up says yes.
  sig { returns(T::Boolean) }
  def step_up_fresh? = false
end
