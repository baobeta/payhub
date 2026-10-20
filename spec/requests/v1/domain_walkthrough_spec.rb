require "rails_helper"

# TC-G7-1: The DOMAIN.md walkthrough, row by row.
#
# Anna pays Demo Shop €25.00. The payment is collected in full, then €10 is
# refunded, then the settlement line (€24.55 + €0.45 fee) arrives.
# After all ten steps the merchant balance must be €15.00 and every ledger
# transfer must net to zero.
#
# Step 6 in the DOMAIN.md table notes "Letters to send +2" — payment.captured
# and capture.succeeded — matching the correction in the TC description
# ("step 9 corrected to 2 outbound events").
RSpec.describe "TC-G7-1: DOMAIN.md walkthrough", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key(webhook_url: "https://shop.test/hooks") }
  let(:merchant) { merchant_and_key.first }
  let(:key) { merchant_and_key.last }
  let(:adapter) { FakePspAdapter.new }

  # A kiripay adapter whose settlement_report always returns nil (no daily report).
  let(:kiripay_adapter) do
    instance_double(KiripayAdapter, name: "kiripay", settlement_report: nil)
  end

  before do
    allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter)
    allow(PspRouter).to receive(:adapter).with("kiripay").and_return(kiripay_adapter)
  end

  def result(status, payment, captured_minor: 0)
    PspAdapter::Result.new(
      status: PspAdapter::Result::Status.deserialize(status.to_s),
      psp_reference: payment.psp_reference,
      psp_charge_id: "ch_nordpay_1",
      decline_code: nil,
      psp_timestamp: payment.created_at + 5.seconds,
      raw: { "captured_minor" => captured_minor }
    )
  end

  def refund_result(refund, payment)
    PspAdapter::RefundResult.new(
      status: PspAdapter::RefundResult::Status::Succeeded,
      psp_reference: refund.psp_reference,
      psp_refund_id: "re_nordpay_1",
      failure_code: nil,
      psp_timestamp: payment.created_at + 20.seconds
    )
  end

  it "writes the rows in DOMAIN.md step by step; balance is €15.00; all transfers net to zero" do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    # ── Step 1: Shop sends "pay €25.00" with ticket ────────────────────────────
    idem = SecureRandom.uuid
    post "/v1/payments",
         params: { amount_minor: 2500, currency: "EUR", payment_method_token: "tok_visa" }.to_json,
         headers: auth_headers(key, idempotency_key: idem)
    expect(response).to have_http_status(:accepted)

    payment = Payment.find(json_body["id"])
    expect(payment.state).to eq("pending")

    # Request ticket (idempotency key) was claimed
    expect(IdempotencyKey.find_by(key: idem)).to be_present
    # Payment history: pending row
    expect(payment.transitions.pluck(:to_state)).to include("pending")
    # payment.created outbound event
    expect(OutboundEvent.where(payment: payment, event_type: "payment.created").count).to eq(1)

    # ── Step 2: Back office charges Nordpay ────────────────────────────────────
    adapter.script(:authorize, result(:authorized, payment))
    AuthorizePaymentJob.perform_now(payment.id)

    expect(payment.reload.first_sent_at).to be_present

    # ── Step 3: Nordpay approves ───────────────────────────────────────────────
    payment.reload
    expect(payment.state).to eq("authorized")
    # Payment history: authorized
    expect(payment.transitions.pluck(:to_state)).to include("authorized")
    # payment.authorized outbound event
    expect(OutboundEvent.where(payment: payment, event_type: "payment.authorized").count).to eq(1)

    # ── Step 4: Night watch delivers the letter ────────────────────────────────
    stub_request(:post, "https://shop.test/hooks").to_return(status: 200)
    DeliverOutboundEventsJob.perform_now
    created_event = OutboundEvent.find_by(payment: payment, event_type: "payment.created")
    auth_event = OutboundEvent.find_by(payment: payment, event_type: "payment.authorized")
    # At least the authorized event is delivered; created may have been delivered too
    [created_event, auth_event].compact.each do |ev|
      expect(ev.reload.state).to eq("delivered")
      expect(ev.delivery_attempts.count).to be >= 1
    end

    # ── Step 5: Shop asks to collect €25.00 ───────────────────────────────────
    cap_idem = SecureRandom.uuid
    post "/v1/payments/#{payment.id}/capture",
         params: "{}",
         headers: auth_headers(key, idempotency_key: cap_idem)
    expect(response).to have_http_status(:accepted)

    # Request ticket for capture
    expect(IdempotencyKey.find_by(key: cap_idem)).to be_present
    capture = payment.captures.sole
    expect(capture).to have_attributes(state: "pending", base_captured_minor: 0)

    # ── Step 6: PayHub checks, then collects ──────────────────────────────────
    adapter.script(:fetch, result(:authorized, payment, captured_minor: 0))
    adapter.script(:capture, result(:authorized, payment, captured_minor: 2500))
    CapturePaymentJob.perform_now(capture.id)

    # Ledger: psp_receivable debit €25 + merchant_payable credit €25
    expect(Ledger.captured_minor(payment.reload)).to eq(2500)
    expect(LedgerEntry.where(payment: payment).count).to eq(2)

    # Capture succeeded, collecting closed (final capture)
    capture.reload
    expect(capture.state).to eq("succeeded")
    expect(payment.reload.captures_closed_at).to be_present

    # Payment history: captured
    expect(payment.transitions.pluck(:to_state)).to include("captured")

    # Step 6 writes 2 outbound events: payment.captured + capture.succeeded
    expect(OutboundEvent.where(payment: payment, event_type: "payment.captured").count).to eq(1)
    expect(OutboundEvent.where(payment: payment, event_type: "capture.succeeded").count).to eq(1)

    # ── Step 7: Nordpay's "charge captured" webhook arrives ──────────────────
    # Already applied; the status doesn't change; the webhook is stored.
    # Script verify_webhook + parse_webhook on the fake so the controller works.
    external_id = "evt_cap_#{SecureRandom.hex(4)}"
    webhook_payload = {
      "id" => external_id,
      "type" => "charge.captured",
      "created_at" => (payment.created_at + 5.seconds).utc.iso8601(3),
      "data" => {
        "id" => "ch_nordpay_1",
        "reference" => payment.psp_reference,
        "status" => "captured",
        "captured_minor" => 2500
      }
    }
    parsed_event = PspAdapter::WebhookEvent.new(
      external_id: external_id, event_type: "charge.captured",
      psp_reference: payment.psp_reference, psp_charge_id: "ch_nordpay_1",
      status: PspAdapter::Result::Status::Captured, decline_code: nil,
      psp_timestamp: payment.created_at + 5.seconds, payload: webhook_payload,
      captured_minor: 2500
    )
    adapter.script(:verify_webhook, parsed_event)
    adapter.script(:parse_webhook, parsed_event)
    nordpay_webhook_body = webhook_payload.to_json
    post "/v1/webhooks/nordpay", params: nordpay_webhook_body,
                                 headers: { "Content-Type" => "application/json", "X-Nordpay-Signature" => "unused" }
    expect(response).to have_http_status(:ok)
    perform_enqueued_jobs

    # Stored exactly once; sending it 5 times would still be once (idempotent)
    expect(InboundEvent.where(external_id: external_id).count).to eq(1)
    # State unchanged: already captured
    expect(payment.reload.state).to eq("captured")
    # Ledger unchanged: still only 2 entries
    expect(LedgerEntry.where(payment: payment).count).to eq(2)

    # ── Step 8: Shop refunds €10.00 ───────────────────────────────────────────
    post "/v1/payments/#{payment.id}/refunds",
         params: { amount_minor: 1000 }.to_json,
         headers: auth_headers(key)
    expect(response).to have_http_status(:accepted)

    refund = payment.refunds.sole
    expect(refund.state).to eq("pending")
    # Reservation: merchant_payable → refunds_reserved (+2 ledger entries)
    expect(LedgerEntry.where(payment: payment).count).to eq(4)
    expect(Ledger.reserved_minor(payment)).to eq(1000)

    # ── Step 9: Nordpay confirms the refund ───────────────────────────────────
    adapter.script(:refund, refund_result(refund, payment))
    RefundPaymentJob.perform_now(refund.id)

    # Ledger: refunds_reserved → refunds_paid (+2 entries)
    expect(LedgerEntry.where(payment: payment).count).to eq(6)
    expect(Ledger.refunded_minor(payment)).to eq(1000)
    expect(Ledger.reserved_minor(payment)).to eq(0)

    refund.reload
    expect(refund.state).to eq("succeeded")

    # Payment history: part_refunded (or refunded if fully refunded, but we only refunded €10)
    payment.reload
    expect(payment.state).to satisfy("be part_refunded or refunded") { |s| %w[part_refunded refunded].include?(s) }

    # Step 9 writes 2 outbound events: payment.part_refunded + refund.succeeded
    expect(OutboundEvent.where(payment: payment, event_type: "refund.succeeded").count).to eq(1)
    expect(
      OutboundEvent.where(payment: payment, event_type: "payment.part_refunded")
                   .or(OutboundEvent.where(payment: payment, event_type: "payment.refunded")).count
    ).to eq(1)

    # ── Step 10: Next day, the payout report ──────────────────────────────────
    settlement_line = PspAdapter::SettlementReportLine.new(
      external_id: "settle_#{SecureRandom.hex(4)}",
      kind: "capture",
      psp_reference: payment.psp_reference,
      refund_reference: nil,
      gross_minor: 2500,
      fee_minor: 45,
      net_minor: 2455,
      currency: "EUR",
      booked_at: Date.current.to_time
    )
    adapter.script(:settlement_report, [settlement_line])
    SettlementReconciliationJob.perform_now(Date.current.yesterday.iso8601)

    # Settlement line written
    line = SettlementLine.find_by(external_id: settlement_line.external_id)
    expect(line).to be_present
    expect(line.status).to eq("matched")

    # Ledger: receivable cleared, fee + payout booked (+2 or 3 entries for the settlement)
    entries_after = LedgerEntry.where(payment: payment).count
    expect(entries_after).to be > 6

    # ── Final checks ─────────────────────────────────────────────────────────
    # Merchant balance: captured €25 - refunded €10 = €15
    balance = Ledger.balances(merchant)
    expect(balance).to eq("EUR" => 1500), "expected €15.00 balance, got #{balance.inspect}"

    # Every transfer must net to zero
    expect(Ledger.unbalanced_transfer_ids).to be_empty

    # Append-only: no updates or deletes in ledger entries or payment transitions
    # (We can't check historical DB writes, but we verify the counts only grew)
    expect(LedgerEntry.where(payment: payment).count).to be >= 8
    expect(payment.transitions.count).to be >= 4
  end
end
