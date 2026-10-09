# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops me", type: :request do
  let(:operator) { create(:operator, role: "ops") }

  it "returns the operator, permissions and no impersonation" do
    sign_in_operator(operator)
    get "/ops/api/me"
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("user", "role")).to eq("ops")
    expect(json_body["permissions"]).to include("ops.queue.read")
    expect(json_body["permissions"]).not_to include("ops.operators.manage")
    expect(json_body["impersonating"]).to be_nil
  end

  it "reports the step-up window" do
    sign_in_operator(operator, stepped_up: true)
    get "/ops/api/me"
    expect(Time.zone.parse(json_body["stepped_up_until"])).to be_within(5.seconds).of(10.minutes.from_now)
  end

  it "reports an active impersonation" do
    merchant = create(:merchant)
    session = sign_in_operator(operator)
    session.start_impersonation!(merchant_id: merchant.id, case_ref: "SUP-42")
    get "/ops/api/me"
    expect(json_body.dig("impersonating", "merchant_id")).to eq(merchant.id)
    expect(json_body.dig("impersonating", "case_ref")).to eq("SUP-42")
    expect(json_body.dig("impersonating", "merchant_name")).to eq(merchant.name)
  end
end
