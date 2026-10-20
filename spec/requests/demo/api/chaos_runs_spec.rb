# frozen_string_literal: true

require "rails_helper"

# The public demo's chaos button. No session, and one run at a time.
RSpec.describe "Demo chaos runs", type: :request do
  before { create(:merchant, name: DemoMerchant::NAME, livemode: true) }

  describe "POST /demo/api/chaos_runs" do
    it "queues a run and answers 202" do
      post "/demo/api/chaos_runs", params: { payments: 5 }

      expect(response).to have_http_status(:accepted)
      expect(json_body["payments"]).to eq(5)
      expect(DemoChaosRun.last.state).to eq("queued")
    end

    it "409s while a run is active, and names it" do
      active = DemoChaosRun.create!(payments: 5)
      post "/demo/api/chaos_runs", params: { payments: 5 }

      expect(response).to have_http_status(:conflict)
      expect(json_body.dig("error", "code")).to eq("chaos_run_in_progress")
      expect(json_body.dig("error", "details", "active_run_id")).to eq([active.id])
    end

    it "clamps a request for more payments to the maximum" do
      post "/demo/api/chaos_runs", params: { payments: 50 }
      expect(json_body["payments"]).to eq(Demo::Api::ChaosRunsController::MAX_PAYMENTS)
    end
  end

  describe "GET /demo/api/chaos_runs/:id" do
    it "returns the run's state and result" do
      run = DemoChaosRun.create!(payments: 5, state: "passed", result: { "passed" => true })
      get "/demo/api/chaos_runs/#{run.id}"

      expect(response).to have_http_status(:ok)
      expect(json_body["state"]).to eq("passed")
      expect(json_body["result"]).to eq("passed" => true)
    end
  end
end
