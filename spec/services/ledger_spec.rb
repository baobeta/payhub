require "rails_helper"

RSpec.describe Ledger do
  let(:payment) { create(:payment) }
  let(:merchant) { payment.merchant }

  describe ".record!" do
    it "refuses an unbalanced transfer before writing anything" do
      legs = [
        Ledger::Leg.new(account_kind: "psp_receivable", direction: "debit", amount_minor: 100),
        Ledger::Leg.new(account_kind: "merchant_payable", direction: "credit", amount_minor: 90)
      ]
      expect { described_class.record!(merchant: merchant, currency: "EUR", legs: legs) }
        .to raise_error(Ledger::Unbalanced, /nets to -10/)
      expect(LedgerEntry.count).to eq(0)
    end

    it "refuses a single-leg transfer" do
      legs = [Ledger::Leg.new(account_kind: "psp_receivable", direction: "debit", amount_minor: 100)]
      expect { described_class.record!(merchant: merchant, currency: "EUR", legs: legs) }
        .to raise_error(Ledger::Unbalanced)
    end

    it "writes both legs under one transfer_id, and they are immutable" do
      described_class.record_capture!(payment, 2500)

      entries = LedgerEntry.where(payment: payment)
      expect(entries.map(&:transfer_id).uniq.size).to eq(1)
      expect(entries.map { |e| [e.account.kind, e.direction, e.amount_minor] })
        .to contain_exactly(["psp_receivable", "debit", 2500], ["merchant_payable", "credit", 2500])
      # Two layers: ActiveRecord refuses first; raw SQL is stopped by the trigger.
      # Each raw statement runs in a savepoint so its failure doesn't abort the example's transaction.
      expect { entries.first.update_column(:amount_minor, 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      raw = lambda do |sql|
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([sql, entries.first.id]))
        end
      end
      expect { raw.call("UPDATE ledger_entries SET amount_minor = 1 WHERE id = ?") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { raw.call("DELETE FROM ledger_entries WHERE id = ?") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  describe "sums" do
    it "derives captured, refunded and balance from rows" do
      described_class.record_capture!(payment, 2500)
      refund = create(:refund, payment: payment, amount_minor: 500, state: "succeeded")
      described_class.record_refund!(refund)

      expect(described_class.captured_minor(payment)).to eq(2500)
      expect(described_class.refunded_minor(payment)).to eq(500)
      expect(described_class.balances(merchant)).to eq("EUR" => 2000)
    end

    it "keeps currencies apart" do
      described_class.record_capture!(payment, 2500)
      vnd = create(:payment, :vnd, merchant: merchant)
      described_class.record_capture!(vnd, 500_000)

      expect(described_class.balances(merchant)).to eq("EUR" => 2500, "VND" => 500_000)
    end

    it "reports no unbalanced transfers when healthy" do
      described_class.record_capture!(payment, 2500)
      expect(described_class.unbalanced_transfer_ids).to be_empty
    end
  end
end
