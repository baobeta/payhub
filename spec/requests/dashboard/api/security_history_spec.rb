# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard security history", type: :request do
  let(:merchant) { create(:merchant) }
  let(:admin) { create(:merchant_user, merchant:, role: "admin") }

  before do
    AuditEvent.record!(action: "api_key.created", result: "success", merchant_id: merchant.id, actor_label: "a@x.test",
                       metadata: { "livemode" => true, "name" => "Server" })
    AuditEvent.record!(action: "api_key.created", result: "success", merchant_id: create(:merchant).id, actor_label: "other@x.test")
  end

  it "lists only this merchant's rows" do
    sign_in_as(admin)
    get "/dashboard/api/security_history"
    expect(json_body["data"].pluck("actor")).to eq(["a@x.test"])
  end

  it "exports CSV with a header and no metadata blobs" do
    sign_in_as(admin)
    get "/dashboard/api/security_history/export.csv"
    expect(response.media_type).to eq("text/csv")
    expect(response.body.lines.first.chomp).to eq("at,actor,action,result,target,ip,livemode")
    expect(response.body).not_to include("Server")
  end

  it "is forbidden to a developer" do
    sign_in_as(create(:merchant_user, merchant:, role: "developer"))
    get "/dashboard/api/security_history"
    expect(response).to have_http_status(:forbidden)
  end
end
