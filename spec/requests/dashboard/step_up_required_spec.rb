# frozen_string_literal: true

require "rails_helper"

# TC-M6-1: every sensitive merchant dashboard mutation without a fresh step-up
# returns 401 step_up_required. The list is derived from the Sensitive column
# in docs/permissions.md and the routes in config/routes.rb.
#
# Covered sensitive permissions and their mutations:
#   payments.cancel       → POST /dashboard/api/payments/:id/cancel
#   payments.capture      → POST /dashboard/api/payments/:id/capture
#   payments.refund       → POST /dashboard/api/payments/:id/refunds
#   api_keys.manage       → POST /dashboard/api/api_keys
#                           POST /dashboard/api/api_keys/:id/roll
#                           POST /dashboard/api/api_keys/:id/revoke
#   team.manage           → POST /dashboard/api/invitations
#                           PATCH /dashboard/api/members/:id
#                           DELETE /dashboard/api/members/:id
#   webhooks.manage       → PATCH /dashboard/api/webhook_endpoint
#                           POST /dashboard/api/webhook_endpoint/roll_secret
#                           POST /dashboard/api/webhook_endpoint/reveal_secret
#   ownership.transfer    → POST /dashboard/api/ownership_transfer
# Credential-level sensitive (require_step_up! before_action, not a permission):
#   n/a (permission)      → PATCH /dashboard/api/me/password
#                           POST /dashboard/api/me/recovery_codes

sensitive_routes = [
  # payments.cancel
  {
    tc: "TC-M6-1 payments.cancel",
    method: :post,
    path: ->(ctx) { "/dashboard/api/payments/#{ctx[:authorized_payment].id}/cancel" },
    params: {}
  },
  # payments.capture
  {
    tc: "TC-M6-1 payments.capture",
    method: :post,
    path: ->(ctx) { "/dashboard/api/payments/#{ctx[:authorized_payment].id}/capture" },
    params: {}
  },
  # payments.refund
  {
    tc: "TC-M6-1 payments.refund",
    method: :post,
    path: ->(ctx) { "/dashboard/api/payments/#{ctx[:captured_payment].id}/refunds" },
    params: { amount_minor: 100, reason: "requested_by_customer" }
  },
  # api_keys.manage – create
  {
    tc: "TC-M6-1 api_keys.manage create",
    method: :post,
    path: ->(_ctx) { "/dashboard/api/api_keys" },
    params: { name: "New Key" }
  },
  # api_keys.manage – roll
  {
    tc: "TC-M6-1 api_keys.manage roll",
    method: :post,
    path: ->(ctx) { "/dashboard/api/api_keys/#{ctx[:api_key].id}/roll" },
    params: { expires_in: "24h" }
  },
  # api_keys.manage – revoke
  {
    tc: "TC-M6-1 api_keys.manage revoke",
    method: :post,
    path: ->(ctx) { "/dashboard/api/api_keys/#{ctx[:api_key].id}/revoke" },
    params: {}
  },
  # team.manage – invite
  {
    tc: "TC-M6-1 team.manage invite",
    method: :post,
    path: ->(_ctx) { "/dashboard/api/invitations" },
    params: { email: "invite@example.com", role: "support" }
  },
  # team.manage – role change
  {
    tc: "TC-M6-1 team.manage role change",
    method: :patch,
    path: ->(ctx) { "/dashboard/api/members/#{ctx[:team_member].id}" },
    params: { role: "support" }
  },
  # team.manage – remove
  {
    tc: "TC-M6-1 team.manage remove",
    method: :delete,
    path: ->(ctx) { "/dashboard/api/members/#{ctx[:team_member].id}" },
    params: {}
  },
  # webhooks.manage – update endpoint URL
  {
    tc: "TC-M6-1 webhooks.manage update",
    method: :patch,
    path: ->(_ctx) { "/dashboard/api/webhook_endpoint" },
    params: { url: "https://example.com/hook" }
  },
  # webhooks.manage – roll secret
  {
    tc: "TC-M6-1 webhooks.manage roll_secret",
    method: :post,
    path: ->(_ctx) { "/dashboard/api/webhook_endpoint/roll_secret" },
    params: {}
  },
  # webhooks.manage – reveal secret
  {
    tc: "TC-M6-1 webhooks.manage reveal_secret",
    method: :post,
    path: ->(_ctx) { "/dashboard/api/webhook_endpoint/reveal_secret" },
    params: {}
  },
  # ownership.transfer
  {
    tc: "TC-M6-1 ownership.transfer",
    method: :post,
    path: ->(_ctx) { "/dashboard/api/ownership_transfer" },
    params: { member_id: nil } # member_id filled dynamically below
  },
  # credential – password change
  {
    tc: "TC-M6-1 me password",
    method: :patch,
    path: ->(_ctx) { "/dashboard/api/me/password" },
    params: { current_password: "wrong", new_password: "new" }
  },
  # credential – recovery codes regeneration
  {
    tc: "TC-M6-1 me recovery_codes",
    method: :post,
    path: ->(_ctx) { "/dashboard/api/me/recovery_codes" },
    params: {}
  }
].freeze

RSpec.describe "TC-M6-1: step-up required for every sensitive merchant mutation", type: :request do
  let(:merchant) { create(:merchant) }

  # An owner holds every sensitive permission.
  let(:owner) { create(:merchant_user, merchant:, role: "owner") }

  # Payments
  let!(:authorized_payment) { create(:payment, merchant:, state: "authorized") }
  let!(:captured_payment) do
    p = create(:payment, merchant:, state: "captured")
    Ledger.record_capture!(p, 2500)
    p
  end

  # API key
  let!(:api_key) { ApiKey.issue!(merchant:, livemode: true, name: "Server").first }

  # Team member (non-owner so it can be modified)
  let!(:team_member) { create(:merchant_user, merchant:, role: "viewer") }

  sensitive_routes.each do |row|
    it "#{row[:tc]}: without step-up → 401 step_up_required" do
      ctx = {
        authorized_payment: authorized_payment,
        captured_payment: captured_payment,
        api_key: api_key,
        team_member: team_member,
        owner: owner
      }

      sign_in_as(owner) # no stepped_up:
      path = row[:path].call(ctx)
      params_hash = row[:params].dup
      # Ownership transfer needs a valid member_id
      params_hash[:member_id] = team_member.id if row[:tc].include?("ownership.transfer")

      public_send(row[:method], path, params: params_hash.to_json, headers: ui_headers)

      expect(response).to have_http_status(:unauthorized),
        "#{row[:tc]}: expected 401, got #{response.status} for #{row[:method].upcase} #{path}"
      expect(json_body.dig("error", "code")).to eq("step_up_required"),
        "#{row[:tc]}: expected step_up_required, got #{json_body.dig("error", "code")}"
    end
  end
end
