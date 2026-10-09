# typed: false
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
# typed: false because Sorbet cannot see the controller API (request,
# before_action, class_attribute) from inside an ActiveSupport::Concern.
# spec/controllers/web/base_controller_authorization_spec.rb covers it.
module Authorization
  extend ActiveSupport::Concern

  class NotDeclared < StandardError; end

  included do
    class_attribute :authorization_rules, instance_writer: false, default: []
    after_action :verify_authorization_declared
  end

  class_methods do
    def requires_permission(permission, only: nil, except: nil)
      raise Permissions::Unknown, "unknown permission #{permission.inspect}" unless Permissions.known?(permission)

      add_authorization_rule(kind: :permission, permission:, only:, except:)
      before_action(**{ only:, except: }.compact) { authorize!(permission) }
    end

    def allow_unauthorized(only: nil, except: nil)
      add_authorization_rule(kind: :public, permission: nil, only:, except:)
      before_action(**{ only:, except: }.compact) { @authorization_checked = true }
    end

    def authorization_declared_for?(action)
      authorization_rules.any? { |rule| rule_applies?(rule, action.to_s) }
    end

    private

    def add_authorization_rule(kind:, permission:, only:, except:)
      self.authorization_rules = authorization_rules + [{
        kind:, permission:,
        only: only && Array(only).map(&:to_s), except: except && Array(except).map(&:to_s)
      }]
    end

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
  def authorize!(permission)
    @authorization_checked = true
    raise ApiError.unauthenticated if authorization_role.nil?

    unless permission_granted?(permission)
      record_denial(permission)
      raise ApiError.forbidden(permission)
    end
    raise ApiError.step_up_required if Permissions.sensitive?(permission) && !step_up_fresh?
  end

  # Phase 2 narrows this for read-only impersonation.
  def permission_granted?(permission)
    Permissions.granted?(authorization_area, authorization_role, permission)
  rescue ArgumentError => e
    raise if e.is_a?(Permissions::Unknown) # a typo in code is a bug, not a denial

    false # unknown role: deny (and audit), never 500
  end

  def record_denial(permission)
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

  def verify_authorization_declared
    return if @authorization_checked

    Metrics.increment(:authz_undeclared, controller: controller_path)
    message = "#{controller_path}##{action_name} ran without requires_permission or allow_unauthorized"
    raise NotDeclared, message unless Rails.env.production?

    Rails.logger.error({ event: "authorization_undeclared", route: "#{controller_path}##{action_name}" }.to_json)
  end

  # Overridden by the area base controllers in phases 1 and 2.
  def authorization_area = raise(NotImplementedError, "#{self.class} must define authorization_area")
  def authorization_role = nil
  def authorization_actor = nil
  def authorization_merchant_id = nil
  # Fail closed: only an area base controller that tracks step-up says yes.
  def step_up_fresh? = false
end
