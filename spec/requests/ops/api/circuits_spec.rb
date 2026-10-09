# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops circuits", type: :request do
  it "returns a snapshot per PSP" do
    sign_in_operator(create(:operator, role: "support"))
    get "/ops/api/circuits", headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(json_body["data"].map { |c| c["psp"] }).to eq(PspRouter::ADAPTERS.keys)
    expect(json_body["data"]).to all(include("state" => "closed"))
  end

  it "refuses a merchant session" do
    sign_in_as(create(:merchant_user))
    get "/ops/api/circuits", headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
  end
end
