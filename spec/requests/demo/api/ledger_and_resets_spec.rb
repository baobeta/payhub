# frozen_string_literal: true

require "rails_helper"

# The public demo's ledger view and reset. No session, append-only truth kept.
RSpec.describe "Demo ledger and reset", type: :request do
  let!(:demo) { create(:merchant, name: DemoMerchant::NAME, livemode: true) }
  let(:twin) { demo.test_twin! }

  before { DemoEpoch.delete_all }

  def transfer(amount: 1000)
    Ledger.record!(merchant: twin, currency: "EUR", legs: [
                      Ledger::Leg.new(account_kind: "psp_receivable", direction: "debit", amount_minor: amount),
                      Ledger::Leg.new(account_kind: "merchant_payable", direction: "credit", amount_minor: amount)
                    ])
  end

  describe "GET /demo/api/ledger_summary" do
    it "shows only post-epoch transfers, each netting to zero" do
      before_epoch = transfer # the epoch has not started yet
      DemoEpoch.create!(started_at: Time.current)
      after = transfer

      get "/demo/api/ledger_summary"

      expect(response).to have_http_status(:ok)
      ids = json_body["transfers"].pluck("transfer_id")
      expect(ids).to contain_exactly(after)
      expect(ids).not_to include(before_epoch)
      expect(json_body["transfers"].first["nets_to_zero"]).to be(true)
      expect(json_body["all_balanced"]).to be(true)
      expect(json_body["transfers"].first["legs"].size).to eq(2)
    end
  end

  describe "POST /demo/api/reset" do
    before { DemoEpoch.create!(started_at: 1.hour.ago) }

    it "starts a new epoch and returns 201" do
      expect { post "/demo/api/reset" }.to change(DemoEpoch, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it "429s when the last reset was less than a minute ago" do
      DemoEpoch.create!(started_at: Time.current)
      post "/demo/api/reset"
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body.dig("error", "code")).to eq("reset_too_soon")
    end

    it "409s while a chaos run is active" do
      DemoChaosRun.create!(payments: 5)
      post "/demo/api/reset"
      expect(response).to have_http_status(:conflict)
      expect(json_body.dig("error", "code")).to eq("chaos_run_in_progress")
    end

    it "hides a previously visible payment after a reset" do
      DemoEpoch.last.update!(started_at: 1.hour.ago)
      payment = create(:payment, merchant: twin)

      get "/demo/api/payments/#{payment.id}"
      expect(response).to have_http_status(:ok)

      post "/demo/api/reset"
      get "/demo/api/payments/#{payment.id}"
      expect(response).to have_http_status(:not_found)
    end

    it "TC-O1-1: a demo reset deletes nothing — Payment and LedgerEntry counts are unchanged" do
      # Create some payments and ledger entries before the reset
      payment = create(:payment, merchant: twin)
      Ledger.record!(
        merchant: twin, currency: "EUR",
        legs: [
          Ledger::Leg.new(account_kind: "psp_receivable", direction: "debit", amount_minor: 1000),
          Ledger::Leg.new(account_kind: "merchant_payable", direction: "credit", amount_minor: 1000)
        ]
      )

      payment_count_before = Payment.count
      ledger_entry_count_before = LedgerEntry.count

      post "/demo/api/reset"
      expect(response).to have_http_status(:created)

      expect(Payment.count).to eq(payment_count_before)
      expect(LedgerEntry.count).to eq(ledger_entry_count_before)
    end
  end
end
