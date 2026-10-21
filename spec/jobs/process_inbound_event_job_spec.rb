require "rails_helper"

RSpec.describe ProcessInboundEventJob do
  let(:payment) { create(:payment) }
  let(:t0) { payment.created_at }

  # A stored, verified Nordpay webhook: { id, type, created_at, data: <charge> }.
  def nordpay_event(status, captured_minor:, at: t0 + 10.seconds, type: "charge.captured")
    payload = { "id" => "evt_#{SecureRandom.hex(4)}", "type" => type, "created_at" => at.utc.iso8601(6),
                "data" => { "id" => "ch_1", "reference" => payment.psp_reference, "status" => status,
                            "captured_minor" => captured_minor } }
    InboundEvent.create!(psp_name: "nordpay", external_id: payload["id"], event_type: type,
                         psp_reference: payment.psp_reference, payload: payload, signature_valid: true,
                         psp_timestamp: at, received_at: Time.current)
  end

  def partly_captured(amount)
    payment.transition!(:authorized, sort_key: t0 + 1.second, source: "worker")
    BookCapture.call(payment, psp_captured_minor: amount, psp_timestamp: t0 + 2.seconds, source: "worker")
  end

  describe "booking the PSP's amount (bug 14)" do
    it "TC-E11-1: a Nordpay capture webhook after a partial capture books the partial amount only" do
      partly_captured(1000)
      event = nordpay_event("captured", captured_minor: 1000)

      described_class.perform_now(event.id)

      expect(Ledger.captured_minor(payment)).to eq(1000)
      expect(event.reload).to have_attributes(processed_at: be_present, error: nil)
    end

    it "books the PSP's running total when it is ahead of the ledger" do
      partly_captured(1000)

      described_class.perform_now(nordpay_event("captured", captured_minor: 2500).id)

      expect(Ledger.captured_minor(payment)).to eq(2500)
    end

    it "TC-E11-2: a Kiripay capture webhook carries no amount, so the full amount is booked, once" do
      vnd = create(:payment, :vnd)
      payload = { "id" => "evt_kp", "type" => "charge.captured", "created_at" => (vnd.created_at + 5).utc.iso8601,
                  "data" => { "id" => "kp_1", "merchant_reference" => vnd.psp_reference, "status" => "captured" } }
      event = InboundEvent.create!(psp_name: "kiripay", external_id: "evt_kp", event_type: "charge.captured",
                                   psp_reference: vnd.psp_reference, payload: payload, signature_valid: true,
                                   psp_timestamp: vnd.created_at + 5, received_at: Time.current)

      2.times { described_class.perform_now(event.id) }

      expect(Ledger.captured_minor(vnd)).to eq(500_000)
      expect(vnd.reload.state).to eq("captured")
    end

    it "TC-E3-15: a partial-capture webhook from Nordpay books progress, not an illegal transition" do
      partly_captured(1000)
      event = nordpay_event("authorized", captured_minor: 1000)

      described_class.perform_now(event.id)

      expect(event.reload).to have_attributes(processed_at: be_present, error: nil)
      expect(payment.reload.state).to eq("captured")
      expect(Ledger.captured_minor(payment)).to eq(1000)
    end

    it "books a later partial capture reported as authorized-with-captured_minor, from part_refunded" do
      partly_captured(1000)
      payment.transition!(:part_refunded, sort_key: t0 + 3.seconds, source: "worker")

      described_class.perform_now(nordpay_event("authorized", captured_minor: 1800).id)

      expect(Ledger.captured_minor(payment)).to eq(1800)
      expect(payment.reload.state).to eq("part_refunded")
    end
  end

  describe "a late success after a local failure (TC-B3-3)" do
    before do
      payment.transition!(:failed, sort_key: t0 + 1.second, source: "sweeper",
                                   metadata: { "decline_code" => "customer_action_expired" })
      allow(Metrics).to receive(:increment).and_call_original
      allow(Rails.logger).to receive(:error).and_call_original
    end

    it "TC-B3-3: is stored with an error, logged loudly and counted, and books nothing" do
      event = nordpay_event("captured", captured_minor: 2500)

      described_class.perform_now(event.id)

      expect(event.reload.processed_at).to be_present
      expect(event.error).to include("late_success_after_failure")
      expect(Rails.logger).to have_received(:error).with(a_string_including('"event":"webhook.late_success_after_failure"'))
      expect(Metrics).to have_received(:increment).with(:late_success, psp: "nordpay")
      expect(payment.reload.state).to eq("failed")
      expect(Ledger.captured_minor(payment)).to eq(0)
    end

    it "puts the payment in the ops queue for a human to refund" do
      described_class.perform_now(nordpay_event("authorized", captured_minor: 0, type: "charge.authorized").id)

      expect(OpsQueue.call["late_successes"]).to contain_exactly(include("id" => payment.id, "psp_name" => "nordpay"))
    end
  end
end
