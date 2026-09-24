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
