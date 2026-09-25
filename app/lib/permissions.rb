# typed: strict
# frozen_string_literal: true

# The single source of truth for who may do what (design §3).
#
# Rules:
# - Code checks permissions, never role names.
# - Permission names are `resource.verb`; operator permissions live under `ops.`.
# - Every role lists its permissions explicitly. No wildcards: a wildcard would
#   silently grant permissions added later.
# - `rake permissions:export` generates docs/permissions.md and the TypeScript
#   union from this file. CI fails if either is stale.
module Permissions
  extend T::Sig

  class Unknown < ArgumentError; end

  CATALOGUE = T.let(
    {
      # ── Merchant ────────────────────────────────────────────────────────
      "payments.read" => { description: "List and view payments and their timelines", sensitive: false },
      "payments.export" => { description: "Export the payment list as CSV", sensitive: false },
      "payments.capture" => { description: "Capture an authorised payment", sensitive: true },
      "payments.cancel" => { description: "Cancel an authorised payment", sensitive: true },
      "payments.refund" => { description: "Refund a captured payment", sensitive: true },
      "balance.read" => { description: "View balances per currency", sensitive: false },
      "settlements.read" => { description: "View settlements and PSP fees", sensitive: false },
      "api_keys.read" => { description: "List API keys (never the secret)", sensitive: false },
      "api_keys.manage" => { description: "Create, roll and revoke API keys", sensitive: true },
      "webhooks.read" => { description: "View the webhook endpoint and delivery log", sensitive: false },
      "webhooks.manage" => { description: "Change the endpoint, reveal or roll the signing secret", sensitive: true },
      "events.redeliver" => { description: "Resend an outbound event", sensitive: false },
      "team.read" => { description: "List team members and invitations", sensitive: false },
      "team.manage" => { description: "Invite, change roles of and remove team members", sensitive: true },
      "security_history.read" => { description: "Read and export the security history", sensitive: false },
      "ownership.transfer" => { description: "Transfer account ownership", sensitive: true },
      # ── Operator ────────────────────────────────────────────────────────
      "ops.payments.read" => { description: "Search and view payments across merchants", sensitive: false },
      "ops.queue.read" => { description: "View the needs-attention queue", sensitive: false },
      "ops.circuits.read" => { description: "View PSP circuit breaker state", sensitive: false },
      "ops.reconciliation.read" => { description: "View reconciliation and settlement breaks", sensitive: false },
      "ops.audit.read" => { description: "Read the operator audit stream", sensitive: false },
      "ops.payments.poll" => { description: "Poll the PSP for one payment now", sensitive: false },
      "ops.events.redeliver" => { description: "Redeliver a dead-lettered event", sensitive: false },
      "ops.impersonation.start" => { description: "View a merchant's dashboard read-only", sensitive: true },
      "ops.reconciliation.review" => { description: "Mark a reconciliation break reviewed", sensitive: false },
      "ops.proposals.create" => { description: "Propose a manual transition or ledger correction", sensitive: true },
      "ops.proposals.decide" => { description: "Approve or reject another operator's proposal", sensitive: true },
      "ops.operators.manage" => { description: "Add operators and assign roles", sensitive: true },
      "ops.access_review.export" => { description: "Export who holds which role", sensitive: false }
    }.freeze,
    T::Hash[String, T::Hash[Symbol, T.untyped]]
  )

  OPS_READ = T.let(
    Set["ops.payments.read", "ops.queue.read", "ops.circuits.read", "ops.reconciliation.read", "ops.audit.read"].freeze,
    T::Set[String]
  )

  MERCHANT = T.let(
    {
      "owner" => Set[
        "payments.read", "payments.export", "payments.capture", "payments.cancel", "payments.refund",
        "balance.read", "settlements.read", "api_keys.read", "api_keys.manage", "webhooks.read",
        "webhooks.manage", "events.redeliver", "team.read", "team.manage", "security_history.read",
        "ownership.transfer"
      ].freeze,
      "admin" => Set[
        "payments.read", "payments.export", "payments.capture", "payments.cancel", "payments.refund",
        "balance.read", "settlements.read", "api_keys.read", "api_keys.manage", "webhooks.read",
        "webhooks.manage", "events.redeliver", "team.read", "team.manage", "security_history.read"
      ].freeze,
      "developer" => Set[
        "payments.read", "api_keys.read", "api_keys.manage", "webhooks.read", "webhooks.manage", "events.redeliver"
      ].freeze,
      "support" => Set["payments.read", "payments.capture", "payments.cancel", "payments.refund"].freeze,
      "viewer" => Set["payments.read", "payments.export", "balance.read", "settlements.read"].freeze
    }.freeze,
    T::Hash[String, T::Set[String]]
  )

  OPERATOR = T.let(
    {
      "support" => (OPS_READ | Set["ops.payments.poll", "ops.events.redeliver", "ops.impersonation.start"]).freeze,
      "ops" => (OPS_READ | Set[
        "ops.payments.poll", "ops.events.redeliver", "ops.impersonation.start",
        "ops.reconciliation.review", "ops.proposals.create"
      ]).freeze,
      "approver" => (OPS_READ | Set["ops.proposals.decide"]).freeze,
      "admin" => (OPS_READ | Set["ops.operators.manage", "ops.access_review.export"]).freeze
    }.freeze,
    T::Hash[String, T::Set[String]]
  )

  AREAS = T.let({ merchant: MERCHANT, operator: OPERATOR }.freeze, T::Hash[Symbol, T::Hash[String, T::Set[String]]])

  sig { params(area: Symbol, role: String, permission: String).returns(T::Boolean) }
  def self.granted?(area, role, permission)
    raise Unknown, "unknown permission #{permission.inspect}" unless CATALOGUE.key?(permission)

    self.for(area, role).include?(permission)
  end

  sig { params(area: Symbol, role: String).returns(T::Set[String]) }
  def self.for(area, role)
    AREAS.fetch(area) { raise ArgumentError, "unknown area #{area.inspect}" }
         .fetch(role) { raise ArgumentError, "unknown #{area} role #{role.inspect}" }
  end

  sig { params(permission: String).returns(T::Boolean) }
  def self.sensitive?(permission)
    CATALOGUE.fetch(permission) { raise Unknown, "unknown permission #{permission.inspect}" }.fetch(:sensitive)
  end

  sig { params(permission: String).returns(T::Boolean) }
  def self.known?(permission) = CATALOGUE.key?(permission)

  # Run at boot (config/initializers/permissions.rb). A role that references a
  # permission missing from the catalogue is a typo, and must stop the app.
  sig { void }
  def self.validate!
    AREAS.each do |area, roles|
      roles.each do |role, perms|
        unknown = perms.to_a - CATALOGUE.keys
        raise Unknown, "#{area} role #{role} references unknown permissions: #{unknown.join(', ')}" if unknown.any?

        wrong_ns = area == :operator ? perms.reject { |p| p.start_with?("ops.") } : perms.select { |p| p.start_with?("ops.") }
        raise ArgumentError, "#{area} role #{role} holds permissions from the other area: #{wrong_ns.join(', ')}" if wrong_ns.any?
      end
    end
  end
end
