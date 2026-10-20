require "rails_helper"

RSpec.describe ExpireAuthorizationsJob do
  let(:adapter) { FakePspAdapter.new }

  before { allow(PspRouter).to receive(:adapter).and_return(adapter) }

  # Authorized `idle_for` ago, with the PSP timestamps to match, so a void
  # stamped now is newer and applies.
  def authorized(idle_for:)
    create(:payment, created_at: (idle_for + 1.minute).ago).tap do |p|
      p.transition!(:authorized, sort_key: p.created_at + 1.second, source: "worker")
      p.update_column(:updated_at, idle_for.ago)
    end
  end

  def canceled(payment)
    PspAdapter::Result.new(status: PspAdapter::Result::Status::Canceled, psp_reference: payment.psp_reference,
                           psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: Time.current)
  end

  it "voids a hold nobody captured within the limit, and tells the merchant why" do
    stale = authorized(idle_for: 7.days)
    adapter.script(:cancel, -> { canceled(stale) })

    described_class.perform_now

    expect(stale.reload.state).to eq("canceled")
    last = stale.transitions.find_by(most_recent: true)
    expect(last).to have_attributes(source: "sweeper", metadata: include("reason" => "authorization_expired"))
    expect(OutboundEvent.where(payment: stale, event_type: "payment.canceled")).to exist
  end

  it "leaves holds younger than the limit alone" do
    authorized(idle_for: 5.days)

    described_class.perform_now

    expect(adapter.calls[:cancel]).to be_empty
  end

  it "does not void a payment whose capture was just requested — the capture restarts the clock" do
    payment = authorized(idle_for: 7.days)
    CapturePayment.call(payment)

    described_class.perform_now

    expect(adapter.calls[:cancel]).to be_empty
    expect(payment.reload.state).to eq("authorized")
  end

  it "TC-E3-16: closes the open remainder of a partly captured payment instead of voiding it" do
    partly = authorized(idle_for: 7.days)
    Ledger.record_capture!(partly, 1000)
    partly.update_column(:captured_minor, 1000)
    partly.transition!(:captured, sort_key: partly.created_at + 2.seconds, source: "worker")
    partly.update_column(:updated_at, 7.days.ago)
    nothing_captured = authorized(idle_for: 7.days)
    adapter.script(:cancel, -> { canceled(nothing_captured) })

    described_class.perform_now

    expect(partly.reload).to have_attributes(state: "captured", captures_closed_at: be_present)
    event = OutboundEvent.find_by!(payment: partly, event_type: "payment.captures_closed")
    expect(event.payload).to include("reason" => "authorization_expired", "released_minor" => 1500)
    expect(adapter.calls[:cancel]).to eq([nothing_captured]) # no void for the partly captured one
    expect(nothing_captured.reload.state).to eq("canceled")
  end

  it "closes a fully refunded part_refunded payment into refunded when its remainder expires" do
    payment = authorized(idle_for: 7.days)
    Ledger.record_capture!(payment, 1000)
    payment.update_column(:captured_minor, 1000)
    payment.transition!(:captured, sort_key: payment.created_at + 2.seconds, source: "worker")
    refund = create(:refund, payment: payment, amount_minor: 1000)
    Ledger.post_refund!(refund)
    refund.update!(state: "succeeded")
    payment.transition!(:part_refunded, sort_key: payment.created_at + 3.seconds, source: "worker")
    payment.update_column(:updated_at, 7.days.ago)

    described_class.perform_now

    expect(payment.reload.state).to eq("refunded")
  end

  it "TC-G6-4: skips a PSP that cannot void, and says so once" do
    kiripay = FakePspAdapter.new(name: "kiripay", currencies: %w[VND], void: false)
    allow(PspRouter).to receive(:adapter).with("kiripay").and_return(kiripay)
    payment = create(:payment, :vnd, created_at: 8.days.ago).tap do |p|
      p.transition!(:authorized, sort_key: p.created_at + 1.second, source: "worker")
      p.update_column(:updated_at, 7.days.ago)
    end
    allow(Rails.logger).to receive(:warn).and_call_original

    2.times { described_class.perform_now }

    expect(kiripay.calls[:cancel]).to be_empty
    expect(payment.reload.state).to eq("authorized")
    expect(Rails.logger).to have_received(:warn).with(a_string_including('"event":"authorization.expiry_unsupported"')).once
  end

  describe "TC-G4-1: expiry boundary exactly 6 days vs 6 days − 1 minute" do
    it "TC-G4-1a: a payment idle for exactly 6 days is expired" do
      # updated_at = exactly HOLD_LIMIT ago → idle >= HOLD_LIMIT → must expire
      stale = authorized(idle_for: described_class::HOLD_LIMIT)
      adapter.script(:cancel, -> { canceled(stale) })

      described_class.perform_now

      expect(stale.reload.state).to eq("canceled")
    end

    it "TC-G4-1b: a payment idle for 6 days − 1 minute is left alone" do
      # updated_at = 1 minute under the limit → not yet idle enough
      fresh_enough = authorized(idle_for: described_class::HOLD_LIMIT - 1.minute)

      described_class.perform_now

      expect(fresh_enough.reload.state).to eq("authorized")
      expect(adapter.calls[:cancel]).to be_empty
    end
  end

  it "backs off a void the PSP refuses, without blocking the rest of the batch" do
    refused = authorized(idle_for: 8.days)
    ok = authorized(idle_for: 7.days)
    adapter.script(:cancel, PspAdapter::Unavailable, -> { canceled(ok) })
    allow(Rails.logger).to receive(:error).and_call_original

    described_class.perform_now

    expect(ok.reload.state).to eq("canceled")
    expect(refused.reload).to have_attributes(state: "authorized", check_attempts: 1)
    expect(refused.next_check_at).to be > Time.current
    expect(Rails.logger).to have_received(:error).with(a_string_including('"event":"authorization.expiry_failed"'))

    described_class.perform_now # not due again yet: no scripted answer needed
    expect(adapter.calls[:cancel].size).to eq(2)
  end
end
