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

  it "TC-B3-4: a Kiripay decline webhook moves requires_action to failed, with the decline code and payment.failed" do
    t0 = payment.created_at + 1.second
    deliver(kiripay_event("charge.created", "pending_redirect", at: t0))
    perform_enqueued_jobs
    expect(payment.reload.state).to eq("requires_action")

    declined = kiripay_event("charge.declined", "declined", at: t0 + 30)
    declined["data"]["code"] = "wallet_declined"
    deliver(declined)
    perform_enqueued_jobs

    expect(payment.reload.state).to eq("failed")
    expect(payment.transitions.find_by(most_recent: true).metadata).to include("decline_code" => "wallet_declined")
    expect(OutboundEvent.where(payment: payment, event_type: "payment.failed").count).to eq(1)
  end

  it "TC-D7-1: a Nordpay charge.authorized webhook resolves unknown → authorized and clears next_check_at" do
    nordpay_payment = create(:payment, psp_reference: "ph_np_d7")
    nordpay_payment.update_columns(state: "unknown", first_sent_at: nordpay_payment.created_at,
                                   next_check_at: 5.minutes.from_now)
    nordpay_secret = "np_whsec_test"

    t0 = nordpay_payment.created_at + 5.seconds
    event = {
      "id" => "evt_d7_#{SecureRandom.hex(4)}",
      "type" => "charge.authorized",
      "created_at" => t0.utc.iso8601(3),
      "data" => { "id" => "np_ch_d7", "reference" => "ph_np_d7", "status" => "authorized", "captured_minor" => 0 }
    }
    body = event.to_json
    sig = OpenSSL::HMAC.hexdigest("SHA256", nordpay_secret, body)
    post "/v1/webhooks/nordpay", params: body,
                                 headers: { "Content-Type" => "application/json", "X-Nordpay-Signature" => sig }
    expect(response).to have_http_status(:ok)
    perform_enqueued_jobs

    expect(nordpay_payment.reload.state).to eq("authorized")
    expect(nordpay_payment.next_check_at).to be_nil
  end

  it "TC-D1-1: a valid signed Nordpay charge.authorized webhook returns 200 and authorizes the payment" do
    nordpay_payment = create(:payment, psp_reference: "ph_np1")
    nordpay_secret = "np_whsec_test"

    event = {
      "id" => "evt_np_#{SecureRandom.hex(4)}",
      "type" => "charge.authorized",
      "created_at" => (nordpay_payment.created_at + 5.seconds).utc.iso8601(3),
      "data" => {
        "id" => "np_ch_1",
        "reference" => "ph_np1",
        "status" => "authorized",
        "captured_minor" => 0
      }
    }
    body = event.to_json
    sig = OpenSSL::HMAC.hexdigest("SHA256", nordpay_secret, body)

    post "/v1/webhooks/nordpay", params: body,
                                 headers: { "Content-Type" => "application/json", "X-Nordpay-Signature" => sig }

    expect(response).to have_http_status(:ok)
    perform_enqueued_jobs

    stored = InboundEvent.find_by(psp_name: "nordpay", external_id: event["id"])
    expect(stored).to be_present
    expect(stored.signature_valid).to be true
    expect(nordpay_payment.reload.state).to eq("authorized")
  end

  it "TC-D2-1: a bad Nordpay signature returns 401, stores the event with signature_valid false, never processes" do
    nordpay_payment = create(:payment, psp_reference: "ph_np2")

    event = {
      "id" => "evt_np_bad_#{SecureRandom.hex(4)}",
      "type" => "charge.authorized",
      "created_at" => (nordpay_payment.created_at + 5.seconds).utc.iso8601(3),
      "data" => { "id" => "np_ch_2", "reference" => "ph_np2", "status" => "authorized", "captured_minor" => 0 }
    }
    body = event.to_json

    post "/v1/webhooks/nordpay", params: body,
                                 headers: { "Content-Type" => "application/json", "X-Nordpay-Signature" => "wrong_sig" }

    expect(response).to have_http_status(:unauthorized)
    stored = InboundEvent.find_by(event_type: "unverified", psp_name: "nordpay")
    expect(stored).to be_present
    expect(stored.signature_valid).to be false
    perform_enqueued_jobs
    expect(nordpay_payment.reload.state).to eq("pending")
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
