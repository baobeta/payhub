require "rails_helper"

RSpec.describe SettlementReconciliationJob do
  let(:adapter) { FakePspAdapter.new }
  let(:payment) { create(:payment, amount_minor: 10_000) }
  let(:day) { Date.new(2026, 9, 23) }

  before do
    allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter)
    allow(PspRouter).to receive(:adapter).with("kiripay").and_return(KiripayAdapter.new) # publishes no report
    Ledger.record_capture!(payment, 10_000)
  end

  def line(kind: "capture", ref: payment.psp_reference, gross: 10_000, fee: 165, refund_reference: nil, id: SecureRandom.hex(4))
    PspAdapter::SettlementReportLine.new(
      external_id: "stl_#{id}", kind: kind, psp_reference: ref, refund_reference: refund_reference,
      gross_minor: gross, fee_minor: fee, net_minor: kind == "capture" ? gross - fee : -gross,
      currency: "EUR", booked_at: day.to_time
    )
  end

  def run(*lines)
    adapter.script(:settlement_report, lines)
    described_class.perform_now(day.iso8601)
  end

  def balance(kind) = LedgerAccount.find_by(merchant: payment.merchant, kind: kind, currency: "EUR")&.balance_minor.to_i

  it "books a matched capture: the receivable clears, the fee and the payout are recorded" do
    run(line)

    expect(SettlementLine.last).to have_attributes(status: "matched", payment_id: payment.id)
    expect(Ledger.settled_minor(payment)).to eq(10_000)
    expect([balance("psp_receivable"), balance("psp_fees"), balance("psp_payouts")]).to eq([0, -165, -9835])
    expect(Ledger.captured_minor(payment)).to eq(10_000) # captured is history, not a balance
    expect(Ledger.unbalanced_transfer_ids).to be_empty
  end

  it "books a matched refund against refunds_paid" do
    refund = create(:refund, payment: payment, amount_minor: 2500)
    Ledger.post_refund!(refund)
    refund.update!(state: "succeeded")

    run(line, line(kind: "refund", gross: 2500, fee: 0, refund_reference: refund.psp_reference))

    expect(SettlementLine.pluck(:status)).to eq(%w[matched matched])
    expect(balance("refunds_paid")).to eq(0)
    expect(balance("psp_payouts")).to eq(-(9835 - 2500))
    expect(Ledger.refunded_minor(payment)).to eq(2500)
  end

  describe "discrepancies — stored, logged, counted, never booked" do
    before { allow(Rails.logger).to receive(:error).and_call_original }

    it "a line for a reference we have never seen: money moved that we know nothing about" do
      run(line(ref: "ph_nobody"))

      expect(SettlementLine.last).to have_attributes(status: "unmatched", payment_id: nil)
      expect(Rails.logger).to have_received(:error).with(a_string_including('"event":"settlement.discrepancy"', "ph_nobody"))
      expect(Ledger.settled_minor(payment)).to eq(0)
    end

    it "a capture settling more than the ledger captured: the PSP took money we never booked" do
      run(line(gross: 6000, fee: 109), line(gross: 6000, fee: 109))

      expect(SettlementLine.order(:created_at).pluck(:status)).to eq(%w[matched mismatch])
      expect(SettlementLine.find_by(status: "mismatch").problem).to include("ledger captured only 10000")
      expect(Ledger.settled_minor(payment)).to eq(6000)
    end

    it "a refund the PSP paid that our books still show as pending" do
      refund = create(:refund, payment: payment, amount_minor: 2500) # pending, reserved

      run(line(kind: "refund", gross: 2500, fee: 0, refund_reference: refund.psp_reference))

      expect(SettlementLine.last).to have_attributes(status: "mismatch", refund_id: refund.id, problem: "refund is pending in our books")
    end
  end

  it "ingests each line once, however often the report is fetched" do
    same = line(id: "fixed")
    run(same)
    entries = LedgerEntry.count

    run(same)

    expect(SettlementLine.count).to eq(1)
    expect(LedgerEntry.count).to eq(entries)
  end

  it "flags a capture the PSP has not settled within #{described_class::SETTLE_WITHIN.inspect}" do
    settled = create(:payment)
    Ledger.record_capture!(settled, 500)
    allow(Rails.logger).to receive(:warn).and_call_original

    travel 4.days do
      run(line(ref: settled.psp_reference, gross: 500, fee: 32))
    end

    expect(Rails.logger).to have_received(:warn).with(a_string_including("settlement.unsettled_capture", payment.id)).once
    expect(Rails.logger).not_to have_received(:warn).with(a_string_including(settled.id))
  end

  it "skips a PSP that publishes no report, and survives one whose report is unavailable" do
    adapter.script(:settlement_report, PspAdapter::Unavailable)
    allow(Rails.logger).to receive(:error).and_call_original

    expect { described_class.perform_now(day.iso8601) }.not_to raise_error
    expect(Rails.logger).to have_received(:error).with(a_string_including("settlement.report_unavailable"))
  end
end
