# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplyPspResult do
  let(:payment) { create(:payment, amount_minor: 2500) }
  let(:at) { payment.created_at + 5.seconds }

  def result(status, **attrs)
    PspAdapter::Result.new(status: PspAdapter::Result::Status.const_get(status), psp_reference: payment.psp_reference,
                           psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: at, **attrs)
  end

  def apply(res) = described_class.call(payment, res, source: "worker")

  def authorize! = payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")

  def states = payment.transitions.where.not(from_state: nil).order(:sort_key).pluck(:to_state)

  it "TC-COV-APR-1 records a void of a pending payment as authorized, then canceled" do
    apply(result(:Canceled))

    expect(payment.reload.state).to eq("canceled")
    expect(payment.transitions.order(:sort_key).last(2).map(&:to_state)).to eq(%w[authorized canceled])
  end

  it "TC-COV-APR-2 cancels an authorized payment directly" do
    authorize!

    expect { apply(result(:Canceled)) }.to change { payment.transitions.count }.by(1)
    expect(payment.reload.state).to eq("canceled")
  end

  it "TC-COV-APR-3 fails loudly when a NotFound reaches it (callers resend first)" do
    expect { apply(result(:NotFound)) }.to raise_error(ArgumentError, /NotFound reached ApplyPspResult/)
  end

  it "TC-COV-APR-4 books a capture on an authorized payment without a second authorize" do
    authorize!

    apply(result(:Captured, raw: { "captured_minor" => 1000 }))

    expect(payment.reload.state).to eq("captured")
    expect(payment.transitions.where(to_state: "authorized").count).to eq(1)
    expect(Ledger.captured_minor(payment)).to eq(1000)
  end

  it "TC-COV-APR-5 books the full amount when the PSP reports no running total" do
    apply(result(:Captured))

    expect(Ledger.captured_minor(payment)).to eq(2500)
  end

  it "TC-COV-APR-6 treats an answer for the state the payment is already in as done" do
    authorize!
    allow(Rails.logger).to receive(:info)

    expect { apply(result(:Authorized)) }.not_to change { payment.transitions.count }
    expect(Rails.logger).to have_received(:info).with(/psp_result.already_in_state/)
  end

  it "TC-COV-APR-7 lets any other illegal edge propagate" do
    authorize!
    apply(result(:Captured))

    expect { apply(result(:Declined, decline_code: "do_not_honor")) }
      .to raise_error(PaymentStateMachine::IllegalTransition)
    expect(payment.reload.state).to eq("captured")
  end
end
