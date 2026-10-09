# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops queue", type: :request do
  it "lets a support operator read the queue" do
    sign_in_operator(create(:operator, role: "support"))
    get "/ops/api/queue"
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to contain_exactly("unknown_payments", "dead_events", "reconciliation_breaks", "open_proposals")
  end

  it "refuses a merchant session" do
    sign_in_as(create(:merchant_user))
    get "/ops/api/queue"
    expect(response).to have_http_status(:unauthorized)
  end
end
