# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard team", type: :request do
  let(:merchant) { create(:merchant) }
  let!(:owner) { create(:merchant_user, merchant:, role: "owner") }
  let(:admin) { create(:merchant_user, merchant:, role: "admin") }
  let!(:member) { create(:merchant_user, merchant:, role: "viewer") }

  it "lists members of the live merchant only" do
    create(:merchant_user) # another merchant's
    sign_in_as(admin)
    get "/dashboard/api/members"
    expect(json_body["data"].pluck("email")).to contain_exactly(owner.email, admin.email, member.email)
  end

  it "changes a role with step-up and audits from and to" do
    sign_in_as(admin, stepped_up: true)
    patch "/dashboard/api/members/#{member.id}", params: { role: "support" }.to_json, headers: ui_headers
    expect(json_body["role"]).to eq("support")
    expect(AuditEvent.last).to have_attributes(action: "team.role_changed")
    expect(AuditEvent.last.metadata).to include("from" => "viewer", "to" => "support")
  end

  it "answers 409 when a rule refuses" do
    sign_in_as(admin, stepped_up: true)
    patch "/dashboard/api/members/#{owner.id}", params: { role: "viewer" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:conflict)
  end

  it "removes a member, who is signed out at once" do
    sign_in_as(member)
    sign_in_as(admin, stepped_up: true)
    delete "/dashboard/api/members/#{member.id}", headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(member.sessions.where(revoked_at: nil)).to be_empty
  end

  it "cannot touch another merchant's member" do
    sign_in_as(admin, stepped_up: true)
    patch "/dashboard/api/members/#{create(:merchant_user).id}", params: { role: "support" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:not_found)
  end

  describe "ownership transfer" do
    it "is forbidden to an admin" do
      sign_in_as(admin, stepped_up: true)
      post "/dashboard/api/ownership_transfer", params: { member_id: member.id }.to_json, headers: ui_headers
      expect(response).to have_http_status(:forbidden)
    end

    it "moves ownership, emails both people and audits" do
      sign_in_as(owner, stepped_up: true)
      expect do
        post "/dashboard/api/ownership_transfer", params: { member_id: admin.id }.to_json, headers: ui_headers
      end.to have_enqueued_mail(SecurityMailer, :ownership_transferred).twice
      expect([owner.reload.role, admin.reload.role]).to eq(%w[admin owner])
      expect(AuditEvent.last.action).to eq("team.ownership_transferred")
    end
  end
end
