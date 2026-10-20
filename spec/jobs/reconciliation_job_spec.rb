require "rails_helper"

RSpec.describe ReconciliationJob do
  let(:payment) { create(:payment) }
  let(:adapter) { FakePspAdapter.new }

  before { allow(PspRouter).to receive(:adapter).and_return(adapter) }

  def psp_result(payment, captured_minor:)
    PspAdapter::Result.new(
      status: PspAdapter::Result::Status::Captured,
      psp_reference: payment.psp_reference,
      psp_charge_id: "ch_1",
      decline_code: nil,
      psp_timestamp: Time.current,
      raw: { "captured_minor" => captured_minor }
    )
  end

  describe "TC-I1-1: unbalanced transfer raises ledger_imbalance_detected metric + ERROR log" do
    it "TC-I1-1: a raw unbalanced transfer emits the metric and an ERROR log entry" do
      # Insert a transfer whose legs do not net to zero via raw SQL.
      # The append-only trigger blocks UPDATE/DELETE but allows INSERT.
      # We bypass the trigger by using session_replication_role = replica.
      merchant = payment.merchant
      account = LedgerAccount.find_or_create_by!(merchant: merchant, kind: "psp_receivable", currency: "EUR")
      transfer_id = SecureRandom.uuid

      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL session_replication_role = replica")
        ActiveRecord::Base.connection.execute(
          "INSERT INTO ledger_entries (id, transfer_id, account_id, payment_id, direction, amount_minor, currency, created_at) " \
          "VALUES (gen_random_uuid(), '#{transfer_id}', '#{account.id}', '#{payment.id}', 'debit', 1000, 'EUR', NOW())"
          # Only one leg — no matching credit — so it does not net to zero.
        )
      end

      allow(Metrics).to receive(:increment).and_call_original
      allow(Rails.logger).to receive(:error).and_call_original

      described_class.perform_now(1.hour.from_now.iso8601) # empty payment window

      expect(Metrics).to have_received(:increment).with(:ledger_imbalance_detected)
      expect(Rails.logger).to have_received(:error).with(a_string_including("reconciliation.unbalanced_transfer", transfer_id))
    end
  end

  describe "TC-J7-1: captured_minor cache drift and PSP total drift are detected" do
    it "TC-J7-1a: captured_minor cache ≠ ledger is detected and logged" do
      payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")
      Ledger.record_capture!(payment, 2500)
      payment.transition!(:captured, sort_key: payment.created_at + 2.seconds, source: "worker")
      # Corrupt the cache: set captured_minor to a wrong value directly.
      payment.update_column(:captured_minor, 1000)
      allow(Rails.logger).to receive(:error).and_call_original

      # Script fetch so compare_with_psp doesn't error; cache_drift is found before PSP comparison.
      adapter.script(:fetch, psp_result(payment, captured_minor: 2500))

      described_class.perform_now

      expect(Rails.logger).to have_received(:error).with(
        a_string_including("reconciliation.cache_drift", payment.id)
      )
    end

    it "TC-J7-1b: PSP captured total ≠ ledger captured is detected and logged" do
      payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")
      Ledger.record_capture!(payment, 2500)
      payment.update_column(:captured_minor, 2500)
      payment.transition!(:captured, sort_key: payment.created_at + 2.seconds, source: "worker")
      # PSP says 3000, ledger says 2500 — drift!
      allow(Rails.logger).to receive(:error).and_call_original

      adapter.script(:fetch, psp_result(payment, captured_minor: 3000))

      described_class.perform_now

      expect(Rails.logger).to have_received(:error).with(
        a_string_including("reconciliation.psp_drift", payment.id)
      )
    end
  end

  it "flags a refund whose reservation disagrees with its state (DECISIONS #16)" do
    Ledger.record_capture!(payment, 2500)
    healthy = create(:refund, payment: payment, amount_minor: 500)                   # pending, holds 500
    unreserved = create(:refund, payment: payment, amount_minor: 300, state: "failed")
    unreserved.update_column(:state, "pending")                                      # pending, holds nothing
    allow(Rails.logger).to receive(:error).and_call_original

    described_class.perform_now(1.hour.from_now.iso8601) # empty payment window: only the ledger checks run

    expect(Ledger.reservation_drift_refund_ids).to eq([unreserved.id])
    expect(Rails.logger).to have_received(:error).with(a_string_including("reconciliation.reservation_drift", unreserved.id))
    expect(Rails.logger).not_to have_received(:error).with(a_string_including(healthy.id))
  end
end
