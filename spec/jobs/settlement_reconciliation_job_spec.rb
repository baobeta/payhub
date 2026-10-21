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

  def line(kind: "capture", ref: payment.psp_reference, gross: 10_000, fee: 165, refund_reference: nil,
           id: SecureRandom.hex(4), net: nil, currency: "EUR")
    PspAdapter::SettlementReportLine.new(
      external_id: "stl_#{id}", kind: kind, psp_reference: ref, refund_reference: refund_reference,
      gross_minor: gross, fee_minor: fee, net_minor: net || (kind == "capture" ? gross - fee : -gross),
      currency: currency, booked_at: day.to_time
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

    it "TC-J3-1: net ≠ gross − fee is flagged, never booked, and the run continues" do
      expect { run(line(gross: 2500, fee: 45, net: 2400, id: "bad"), line(gross: 2500, fee: 45, id: "good")) }
        .not_to raise_error

      bad = SettlementLine.find_by(external_id: "stl_bad")
      expect(bad).to have_attributes(status: "mismatch", problem: "net 2400 ≠ gross 2500 − fee 45")
      expect(LedgerEntry.joins(:account).where(ledger_accounts: { kind: "psp_fees" }).count).to eq(1)
      expect(SettlementLine.find_by(external_id: "stl_good").status).to eq("matched")
      expect(Ledger.settled_minor(payment)).to eq(2500)
    end

    it "TC-J3-4: a line we cannot store (unknown kind) is counted and logged, and the lines after it still land" do
      allow(Rails.logger).to receive(:error).and_call_original

      expect { run(line(kind: "chargeback", gross: 2500, fee: 0, net: -2500, id: "odd"), line(gross: 2500, fee: 45, id: "after")) }
        .not_to raise_error

      expect(SettlementLine.find_by(external_id: "stl_odd")).to be_nil
      expect(SettlementLine.find_by(external_id: "stl_after").status).to eq("matched")
      expect(Rails.logger).to have_received(:error).with(a_string_including("settlement.line_unreadable", "stl_odd"))
    end

    it "TC-J3-2: a line in another currency than the payment is a mismatch" do
      run(line(currency: "GBP"))

      expect(SettlementLine.last).to have_attributes(status: "mismatch", problem: "currency GBP, payment is EUR")
      expect(Ledger.settled_minor(payment)).to eq(0)
    end

    it "TC-J3-3: a refund line for another amount than our refund is a mismatch" do
      refund = create(:refund, payment: payment, amount_minor: 1000)
      Ledger.post_refund!(refund)
      refund.update!(state: "succeeded")

      run(line(kind: "refund", gross: 900, fee: 0, refund_reference: refund.psp_reference))

      expect(SettlementLine.last).to have_attributes(status: "mismatch", problem: "refund is 1000 in our books")
      expect(balance("refunds_paid")).to eq(1000) # posted, never settled
    end

    it "TC-J4-1: a second, distinct line for an already-settled refund is a mismatch, not a duplicate" do
      refund = create(:refund, payment: payment, amount_minor: 1000)
      Ledger.post_refund!(refund)
      refund.update!(state: "succeeded")
      settles = ->(id) { line(kind: "refund", gross: 1000, fee: 0, refund_reference: refund.psp_reference, id:) }

      run(settles.call("L1"))
      run(settles.call("L2"))

      expect(SettlementLine.find_by(external_id: "stl_L2"))
        .to have_attributes(status: "mismatch", refund_id: refund.id, problem: "refund already settled by stl_L1")
      expect(balance("refunds_paid")).to eq(0) # booked once
      expect(Rails.logger).to have_received(:error).with(a_string_including("settlement.discrepancy", "stl_L2"))
    end

    it "flags a line the ledger refuses to book instead of aborting the run" do
      allow(Ledger).to receive(:record_settlement!).and_call_original
      allow(Ledger).to receive(:record_settlement!).with(having_attributes(external_id: "stl_boom"))
                                                   .and_raise(Ledger::Unbalanced, "transfer nets to 1 EUR, not 0")

      expect { run(line(gross: 2500, fee: 45, id: "boom"), line(gross: 2500, fee: 45, id: "ok")) }.not_to raise_error

      expect(SettlementLine.find_by(external_id: "stl_boom"))
        .to have_attributes(status: "mismatch", problem: a_string_including("nets to 1 EUR"))
      expect(SettlementLine.find_by(external_id: "stl_ok").status).to eq("matched")
    end
  end

  it "TC-J1-2: several capture lines for one payment (multicapture) each settle" do
    split = create(:payment, amount_minor: 2500)
    Ledger.record_capture!(split, 1000)
    Ledger.record_capture!(split, 1500)

    run(line(ref: split.psp_reference, gross: 1000, fee: 39), line(ref: split.psp_reference, gross: 1500, fee: 46))

    expect(SettlementLine.where(payment: split).pluck(:status)).to eq(%w[matched matched])
    expect(Ledger.settled_minor(split)).to eq(2500)
    expect(Ledger.captured_minor(split) - Ledger.settled_minor(split)).to eq(0) # receivable cleared
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

  # Stripe reconciles from transaction history when there is no report
  # (https://docs.stripe.com/payouts/reconciliation): no report is no excuse
  # to stop watching the receivable.
  it "TC-J5-1: for Kiripay, with no report, logs settlement.no_report and still flags an aged capture" do
    wallet = create(:payment, :vnd)
    Ledger.record_capture!(wallet, wallet.amount_minor)
    allow(Rails.logger).to receive(:info).and_call_original
    allow(Rails.logger).to receive(:warn).and_call_original

    travel 4.days do
      run
    end

    expect(Rails.logger).to have_received(:info).with(a_string_including("settlement.no_report", '"psp":"kiripay"'))
    expect(Rails.logger).to have_received(:warn)
      .with(a_string_including("settlement.unsettled_capture", '"psp":"kiripay"', wallet.id)).once
  end
end
