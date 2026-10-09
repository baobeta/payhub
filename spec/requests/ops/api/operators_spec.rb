# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops operators", type: :request do
  let(:admin) { create(:operator, role: "admin") }

  it "lets an admin list and change an operator's role" do
    target = create(:operator, role: "support")
    sign_in_operator(admin, stepped_up: true)

    get "/ops/api/operators", headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(json_body["data"].map { |o| o["email"] }).to include(target.email)

    patch "/ops/api/operators/#{target.id}", params: { role: "approver" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(target.reload.role).to eq("approver")
    expect(AuditEvent.where(action: "operator.role_changed").count).to eq(1)
  end

  it "forbids ops from managing operators" do
    sign_in_operator(create(:operator, role: "ops"), stepped_up: true)
    get "/ops/api/operators", headers: ui_headers
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses an admin changing their own role" do
    sign_in_operator(admin, stepped_up: true)
    patch "/ops/api/operators/#{admin.id}", params: { role: "support" }.to_json, headers: ui_headers
    expect(response).to have_http_status(409)
    expect(admin.reload.role).to eq("admin")
  end

  it "signs a disabled operator out on their next request" do
    target = create(:operator, role: "ops")
    target_session = Session.create!(principal: target, ip: "127.0.0.1", user_agent: "rspec")
    sign_in_operator(admin, stepped_up: true)

    delete "/ops/api/operators/#{target.id}", headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(target.reload.disabled_at).to be_present
    expect(target_session.reload.revoked_at).to be_present

    set_signed_cookie(:_payhub_ops, target_session.id)
    get "/ops/api/me", headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "exports an access review covering staff and merchant users" do
    operator = create(:operator, role: "ops")
    member = create(:merchant_user)
    sign_in_operator(admin, stepped_up: true)

    get "/ops/api/access_review", headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).to include(admin.email, operator.email, member.email)
    expect(response.body).to include("operator,", "merchant,")
  end
end
