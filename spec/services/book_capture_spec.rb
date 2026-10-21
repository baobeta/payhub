# frozen_string_literal: true

require "rails_helper"

RSpec.describe BookCapture do
  let(:payment) do
    create(:payment, amount_minor: 2500).tap do |p|
      p.transition!(:authorized, sort_key: p.created_at + 1.second, source: "worker")
    end
  end

  def book(total)
    described_class.call(payment, psp_captured_minor: total, psp_timestamp: payment.created_at + 2.seconds,
                                  source: "worker")
  end

  it "TC-COV-BC-1 books what the PSP captured beyond the ledger, once" do
    book(1000)
    book(1000)

    expect(Ledger.captured_minor(payment)).to eq(1000)
    expect(payment.reload).to have_attributes(state: "captured", captured_minor: 1000)
  end

  it "TC-COV-BC-2 books only the difference on a later running total" do
    book(1000)
    book(1600)

    expect(Ledger.captured_minor(payment)).to eq(1600)
    expect(payment.transitions.where(to_state: "captured").count).to eq(1)
  end

  describe "capture.exceeds_authorized" do
    before { allow(Rails.logger).to receive(:error) }

    it "TC-COV-BC-3 clamps a PSP total above the authorized amount to the authorized amount" do
      book(3000)

      expect(Ledger.captured_minor(payment)).to eq(2500)
      expect(payment.reload.captured_minor).to eq(2500)
      expect(Rails.logger).to have_received(:error).with(/capture.exceeds_authorized/)
    end

    it "TC-COV-BC-4 tops up to the authorized amount when part is already booked" do
      book(1000)
      book(9999)

      expect(Ledger.captured_minor(payment)).to eq(2500)
    end

    it "TC-COV-BC-5 books nothing more once the authorized amount is booked, but still says so" do
      book(2500)

      expect { book(2600) }.not_to change(LedgerEntry, :count)
      expect(Ledger.captured_minor(payment)).to eq(2500)
      expect(Rails.logger).to have_received(:error).with(/capture.exceeds_authorized/)
    end

    it "TC-COV-BC-6 keeps the ledger balanced when it clamps" do
      book(3000)

      expect(Ledger.unbalanced_transfer_ids).to be_empty
      expect(Ledger.balances(payment.merchant)).to eq("EUR" => 2500)
    end
  end
end
