require "rails_helper"

RSpec.describe "V1 inbound webhooks", type: :request do
  let(:secret) { "kp_whsec_test" }
  let(:payment) { create(:payment, :vnd, psp_reference: "ph_vnd1") }

  def kiripay_event(type, status, id: "evt_#{SecureRandom.hex(4)}", at: Time.current, reference: "ph_vnd1")
    { "id" => id, "type" => type, "created_at" => at.utc.iso8601(3),
      "data" => { "id" => "kp_1", "merchant_reference" => reference, "status" => status, "amount" => "500000",
                  "currency" => "VND", "created_at" => at.utc.iso8601(3) } }
  end

  def deliver(event, secret: self.secret, ts: Time.current.to_i)
    body = event.to_json
    sig = "t=#{ts},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{ts}.#{body}")}"
    post "/v1/webhooks/kiripay", params: body,
                                 headers: { "Content-Type" => "application/json", "X-Kiripay-Signature" => sig }
  end

  before { payment } # exists before any webhook arrives

  it "stores a valid event, processes it, and — for a capture-only PSP — books the ledger" do
    t0 = payment.created_at + 1.second
    deliver(kiripay_event("charge.created", "pending_redirect", at: t0))
    expect(response).to have_http_status(:ok)
    perform_enqueued_jobs
    expect(payment.reload.state).to eq("requires_action")

    deliver(kiripay_event("charge.captured", "captured", at: t0 + 30))
    perform_enqueued_jobs

    expect(payment.reload.state).to eq("captured")
    expect(Ledger.captured_minor(payment)).to eq(500_000)
    expect(payment.transitions.order(:sort_key).map(&:to_state)).to eq(%w[pending requires_action authorized captured])
    expect(InboundEvent.where(psp_name: "kiripay").pluck(:processed_at)).to all(be_present)
  end

  it "makes the same webhook five times a no-op: one row, one processing, 200 every time" do
    ev = kiripay_event("charge.captured", "captured", id: "evt_dup", at: payment.created_at + 5)

    5.times do
      deliver(ev)
      expect(response).to have_http_status(:ok)
    end
    perform_enqueued_jobs

    expect(InboundEvent.where(external_id: "evt_dup").count).to eq(1)
    expect(Ledger.captured_minor(payment)).to eq(500_000) # booked once
    expect(LedgerEntry.where(payment: payment).count).to eq(2)
  end

  it "applies out-of-order events by PSP timestamp: captured first, created second, ends captured" do
    t0 = payment.created_at + 1.second
    deliver(kiripay_event("charge.captured", "captured", at: t0 + 30))
    deliver(kiripay_event("charge.created", "pending_redirect", at: t0))
    perform_enqueued_jobs

    expect(payment.reload.state).to eq("captured")
    stale = payment.transitions.find_by(to_state: "requires_action")
    expect(stale).to be_stale
  end

  it "rejects a wrong signature with 401, STORES it flagged, alerts, and never processes" do
    allow(Metrics).to receive(:increment).and_call_original
    deliver(kiripay_event("charge.captured", "captured"), secret: "wrong")

    expect(response).to have_http_status(:unauthorized)
    stored = InboundEvent.last
    expect(stored.signature_valid).to be false
    expect(stored.error).to include("mismatch")
    expect(Metrics).to have_received(:increment).with(:webhook_signature_failures, psp: "kiripay")
    perform_enqueued_jobs
    expect(payment.reload.state).to eq("pending")
    expect(Ledger.captured_minor(payment)).to eq(0)
  end

  it "still applies a webhook that arrives hours late if it is the newest thing we know, and records the lag" do
    late_event = kiripay_event("charge.captured", "captured", at: payment.created_at + 1.second)
    travel_to(payment.created_at + 6.hours) do
      deliver(late_event)
      perform_enqueued_jobs
    end

    expect(payment.reload.state).to eq("captured")
    lag_ms = payment.transitions.find_by(to_state: "captured").metadata["lag_ms"]
    expect(lag_ms).to be_within(2_000).of((6.hours - 1.second).in_milliseconds)
  end

  it "leaves an event for an unknown reference unprocessed (orphan) without failing" do
    deliver(kiripay_event("charge.captured", "captured", reference: "ph_never_sent"))
    expect(response).to have_http_status(:ok)
    perform_enqueued_jobs

    expect(InboundEvent.last.processed_at).to be_nil
  end

  it "400s a malformed body and 404s an unknown PSP" do
    ts = Time.current.to_i
    sig = "t=#{ts},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{ts}.{}")}"
    post "/v1/webhooks/kiripay", params: "{}", headers: { "Content-Type" => "application/json", "X-Kiripay-Signature" => sig }
    expect(response).to have_http_status(:bad_request)

    post "/v1/webhooks/paypal", params: "{}", headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:not_found)
  end
end
