# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops impersonation", type: :request do
  let(:operator) { create(:operator, role: "support") }
  let(:merchant) { create(:merchant) }

  def start(merchant_id:, case_reference: "OPS-1")
    post "/ops/api/impersonations", params: { merchant_id:, case_reference: }.to_json, headers: ui_headers
  end

  it "lets support view a merchant's live payments read-only" do
    payment = create(:payment, merchant:)
    sign_in_operator(operator, stepped_up: true)
    start(merchant_id: merchant.id)
    expect(response).to have_http_status(:created)

    get "/ops/api/as/#{merchant.id}/payments", headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(payment.id)
  end

  it "refuses to read another merchant under the same impersonation" do
    other = create(:merchant)
    sign_in_operator(operator, stepped_up: true)
    start(merchant_id: merchant.id)

    get "/ops/api/as/#{other.id}/payments", headers: ui_headers
    expect(response).to have_http_status(403)
    expect(json_body.dig("error", "code")).to eq("impersonation_expired")
  end

  it "expires the impersonation after 30 minutes" do
    session = sign_in_operator(operator, stepped_up: true)
    start(merchant_id: merchant.id)
    # Keep the ops session itself alive so only the impersonation can expire.
    session.update_column(:last_active_at, 31.minutes.from_now) # rubocop:disable Rails/SkipsModelValidations

    travel 31.minutes do
      get "/ops/api/as/#{merchant.id}/payments", headers: ui_headers
    end
    expect(response).to have_http_status(403)
    expect(json_body.dig("error", "code")).to eq("impersonation_expired")
  end

  it "rejects a merchant cookie alone with 401" do
    sign_in_as(create(:merchant_user, merchant:))
    get "/ops/api/as/#{merchant.id}/payments", headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an approver the right to start an impersonation" do
    sign_in_operator(create(:operator, role: "approver"), stepped_up: true)
    start(merchant_id: merchant.id)
    expect(response).to have_http_status(:forbidden)
  end

  it "records the impersonation on the merchant's own security history" do
    sign_in_operator(operator, stepped_up: true)
    start(merchant_id: merchant.id)

    sign_in_as(create(:merchant_user, merchant:))
    get "/dashboard/api/security_history", headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(json_body["data"].map { |e| e["action"] }).to include("impersonation.started")
  end
end
