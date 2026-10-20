# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaymentActions do
  let(:grant_all) { ->(_permission) { true } }
  let(:grant_none) { ->(_permission) { false } }

  it "offers capture and cancel only on an authorized payment" do
    payment = create(:payment, state: "authorized")
    expect(described_class.call(payment, granted: grant_all)).to include("capture" => true, "cancel" => true, "refund" => false,
                                                                   "capturable_minor" => 2500)
  end

  it "offers nothing the role lacks, whatever the state" do
    payment = create(:payment, state: "authorized")
    expect(described_class.call(payment, granted: grant_none).values_at("capture", "cancel", "refund")).to all(be(false))
  end

  it "offers refund on a captured payment with money left, and reports how much" do
    payment = create(:payment, state: "captured")
    Ledger.record_capture!(payment, 2500)
    expect(described_class.call(payment, granted: grant_all)).to include("refund" => true, "refundable_minor" => 2500)
  end

  it "does not offer capture while a capture is in flight" do
    payment = create(:payment, state: "authorized")
    payment.captures.create!(amount_minor: 1000, base_captured_minor: 0)
    expect(described_class.call(payment, granted: grant_all)["capture"]).to be(false)
  end

  it "TC-G6-3: offers no cancel on a PSP that cannot void" do
    allow(PspRouter).to receive(:adapter).with("kiripay")
                                         .and_return(FakePspAdapter.new(name: "kiripay", currencies: %w[VND], void: false))
    payment = create(:payment, :vnd, state: "authorized")
    expect(described_class.call(payment, granted: grant_all)).to include("cancel" => false)
  end

  it "keeps offering capture on a partly captured payment while capturing is open, and stops once closed" do
    payment = create(:payment, state: "captured")
    Ledger.record_capture!(payment, 1000)
    expect(described_class.call(payment, granted: grant_all)).to include("capture" => true, "capturable_minor" => 1500)

    payment.update!(captures_closed_at: Time.current)
    expect(described_class.call(payment, granted: grant_all)).to include("capture" => false, "capturable_minor" => 0)
  end

  it "offers no action on an unknown payment, even to a role that holds every permission" do
    expect(described_class.call(create(:payment, state: "unknown"), granted: grant_all).values_at("capture", "cancel", "refund"))
      .to all(be(false))
  end
end
