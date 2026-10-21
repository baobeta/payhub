# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard balance and settlements", type: :request do
  let(:merchant) { create(:merchant) }
  let(:viewer) { create(:merchant_user, merchant:, role: "viewer") }

  def settle(payment, gross:, fee:)
    SettlementLine.create!(psp_name: "nordpay", external_id: SecureRandom.hex(4), settled_on: Date.new(2026, 9, 24),
                           kind: "capture", psp_reference: payment.psp_reference, payment:, gross_minor: gross,
                           fee_minor: fee, net_minor: gross - fee, currency: "EUR", booked_at: Time.current,
                           status: "matched")
  end

  it "shows available and reserved per currency" do
    payment = create(:payment, merchant:, state: "captured")
    Ledger.record_capture!(payment, 2500)
    sign_in_as(viewer)
    get "/dashboard/api/balance"
    expect(json_body["data"]).to eq([{ "currency" => "EUR", "available_minor" => 2500, "reserved_minor" => 0 }])
  end

  it "sums settlements per day for this merchant only" do
    settle(create(:payment, merchant:), gross: 2500, fee: 50)
    settle(create(:payment), gross: 9999, fee: 99) # another merchant's
    sign_in_as(viewer)
    get "/dashboard/api/settlements"
    expect(json_body["data"]).to eq([{ "settled_on" => "2026-09-24", "currency" => "EUR", "gross_minor" => 2500,
                                       "fee_minor" => 50, "net_minor" => 2450 }])
  end

  it "is forbidden to a developer" do
    sign_in_as(create(:merchant_user, merchant:, role: "developer"))
    get "/dashboard/api/balance"
    expect(response).to have_http_status(:forbidden)
    get "/dashboard/api/settlements"
    expect(response).to have_http_status(:forbidden)
  end

  describe "TC-L5-1 the balance follows the session's mode" do
    before do
      Ledger.record_capture!(create(:payment, merchant:, state: "captured", amount_minor: 2500), 2500)
      Ledger.record_capture!(create(:payment, merchant: merchant.test_twin!, state: "captured", amount_minor: 700), 700)
    end

    it "TC-L5-1 a live session sees only the live ledger" do
      sign_in_as(viewer, livemode: true)
      get "/dashboard/api/balance"
      expect(json_body["data"]).to eq([{ "currency" => "EUR", "available_minor" => 2500, "reserved_minor" => 0 }])
    end

    it "TC-L5-1 a test session sees only the test twin's ledger" do
      sign_in_as(viewer, livemode: false)
      get "/dashboard/api/balance"
      expect(json_body["data"]).to eq([{ "currency" => "EUR", "available_minor" => 700, "reserved_minor" => 0 }])
    end
  end
end
