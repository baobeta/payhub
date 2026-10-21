# frozen_string_literal: true

require "rails_helper"

# The verification half of the chaos run (O3): after the HTTP storm, the books
# are held to the PSP's own records. The simulator and the API are stubbed;
# the merchant's payments and ledger are set up as the storm would leave them.
RSpec.describe ChaosRun do
  def psp_url = ENV.fetch("NORDPAY_URL", "http://localhost:4001")
  def api_url = ENV.fetch("CHAOS_api_url", "http://localhost:3000")

  let(:merchant) { create(:merchant) }
  let(:out) { StringIO.new }
  let(:charges) { [] }
  let(:psp_refunds) { {} }

  # Payment A: €10 captured, €6 refunded. Payment B: €15 captured. Both settled.
  let!(:refunded) { captured_payment(1_000) }
  let!(:captured) { captured_payment(1_500) }
  let!(:refund) do
    create(:refund, payment: refunded, amount_minor: 600).tap do |r|
      r.update!(state: "succeeded")
      Ledger.post_refund!(r)
    end
  end

  before do
    [refunded, captured].each { |p| settle(p, p.amount_minor) }
    charges.push(charge(refunded, 1_000), charge(captured, 1_500))
    psp_refunds[refund.psp_reference] = { "status" => "succeeded", "amount_minor" => 600 }

    stub_request(:put, "#{psp_url}/_sim/config").to_return(body: { "decline_rate" => 0 }.to_json)
    stub_request(:get, "#{psp_url}/_sim/charges").to_return { { body: charges.to_json } }
    stub_request(:get, %r{\A#{Regexp.escape(psp_url)}/refunds/}).to_return do |req|
      body = psp_refunds.fetch(req.uri.path.split("/").last) { { "error" => { "code" => "not_found" } } }
      { body: body.to_json }
    end
    stub_request(:post, %r{\A#{Regexp.escape(api_url)}/v1/}).to_return(status: 202, body: "{}")
    # The settlement report is ingested by its own job (spec/jobs); here the
    # lines are already booked.
    allow(SettlementReconciliationJob).to receive(:perform_now)
  end

  def captured_payment(amount)
    create(:payment, merchant:, state: "captured", amount_minor: amount).tap { |p| Ledger.record_capture!(p, amount) }
  end

  def settle(payment, gross, status: "matched")
    line = SettlementLine.create!(psp_name: "nordpay", external_id: SecureRandom.hex(4), settled_on: Date.current,
                                  kind: "capture", psp_reference: payment.psp_reference, payment:, gross_minor: gross,
                                  fee_minor: 0, net_minor: gross, currency: "EUR", booked_at: Time.current, status:)
    Ledger.record_settlement!(line) if status == "matched"
    line
  end

  def charge(payment, captured_minor, reference: payment.psp_reference)
    { "reference" => reference, "status" => "captured", "amount_minor" => payment.amount_minor,
      "captured_minor" => captured_minor, "currency" => "EUR" }
  end

  def run = described_class.new(payments: 2, merchant:, api_key: "sk_test_x", out:).call

  def failed_labels(result) = result[:checks].reject { |c| c[:passed] }.pluck(:label)

  it "TC-O3-1 passes when the books agree with the PSP's records" do
    result = run

    expect(result[:passed]).to be(true), out.string
    expect(result[:final_states]).to eq("captured" => 2)
    expect(out.string).to include("The one rule held.")
  end

  it "TC-O3-2 fails on a PSP charge that matches no payment (an orphan)" do
    # Present before the run started is someone else's; a new one is ours.
    first = true
    stub_request(:get, "#{psp_url}/_sim/charges").to_return do
      list = first ? charges : charges + [charge(captured, 1_500, reference: "pay_minted_by_a_retry")]
      first = false
      { body: list.to_json }
    end

    result = run

    expect(result[:passed]).to be(false)
    expect(failed_labels(result)).to contain_exactly(a_string_including("no orphan PSP charges", "1 unaccounted for"))
  end

  it "TC-O3-3 ignores a stray charge that was already at the PSP before the run" do
    charges << charge(captured, 1_500, reference: "pay_from_an_earlier_run")

    expect(run[:passed]).to be(true), out.string
  end

  it "TC-O3-4 fails when the PSP captured more than the ledger" do
    charges[1] = charge(captured, 2_000)

    result = run

    expect(failed_labels(result)).to contain_exactly(a_string_including("money taken by the PSP == money captured", "1/2"))
    expect(out.string).to include(captured.id)
  end

  it "TC-O3-5 fails when the PSP refunded a different amount than the ledger" do
    psp_refunds[refund.psp_reference] = { "status" => "succeeded", "amount_minor" => 500 }

    expect(failed_labels(run)).to contain_exactly(a_string_including("money refunded by the PSP == refunds in our ledger"))
  end

  it "TC-O3-6 counts a refund the PSP never confirmed as nothing refunded" do
    psp_refunds.delete(refund.psp_reference)

    expect(failed_labels(run)).to contain_exactly(a_string_including("money refunded by the PSP"))
  end

  it "TC-O3-7 fails when a refund reservation is left behind" do
    create(:refund, payment: captured, amount_minor: 100).update!(state: "failed") # reserved, never voided

    expect(failed_labels(run)).to contain_exactly(a_string_including("no refund reservation left"))
  end

  it "TC-O3-8 fails on a settlement line that does not match the ledger" do
    settle(captured, 1_499, status: "mismatch")

    expect(failed_labels(run)).to contain_exactly(a_string_including("settlement report: 3 lines, 1 not matching"))
  end

  it "TC-O3-9 fails when a capture was never settled by the PSP" do
    late = captured_payment(700)
    charges << charge(late, 700)

    result = described_class.new(payments: 3, merchant:, api_key: "sk_test_x", out:).call

    expect(failed_labels(result)).to contain_exactly(a_string_including("every capture fully settled", "2/3"))
  end

  it "TC-O3-10 fails on a ledger transfer that does not net to zero" do
    account = LedgerAccount.for(merchant, "psp_fees", "EUR")
    LedgerEntry.create!(transfer_id: SecureRandom.uuid, account:, payment: captured, direction: "debit",
                        amount_minor: 1, currency: "EUR")

    expect(failed_labels(run)).to contain_exactly(a_string_including("every ledger transfer nets to zero"))
  end

  it "TC-O3-11 fails when the keys made more or fewer payments than asked" do
    result = described_class.new(payments: 3, merchant:, api_key: "sk_test_x", out:).call

    expect(failed_labels(result)).to contain_exactly(a_string_including("idempotency: 3 keys created exactly 3 payments"))
  end

  it "TC-O3-12 makes the PSP hostile for the run and restores its config afterwards" do
    run

    expect(a_request(:put, "#{psp_url}/_sim/config").with(body: described_class::HOSTILE.to_json)).to have_been_made
    expect(a_request(:put, "#{psp_url}/_sim/config").with(body: { "decline_rate" => 0 }.to_json)).to have_been_made
  end

  it "TC-O3-13 sends each payment request COPIES times and races refunds on captured payments" do
    run

    expect(a_request(:post, "#{api_url}/v1/payments")).to have_been_made.times(2 * described_class::COPIES)
    expect(a_request(:post, "#{api_url}/v1/payments/#{captured.id}/refunds").with(body: { amount_minor: 900 }.to_json))
      .to have_been_made.times(3)
  end

  it "TC-O3-14 records a timeout when payments never leave pending" do
    stub_const("ChaosRun::SETTLE_TIMEOUT", -1)
    create(:payment, merchant:, state: "pending")

    result = described_class.new(payments: 3, merchant:, api_key: "sk_test_x", out:).call

    expect(result[:passed]).to be(false)
    expect(out.string).to include("violation(s)")
  end
end
