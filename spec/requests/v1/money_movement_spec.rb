require "rails_helper"

RSpec.describe "V1 capture / cancel / refunds / balance", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key }
  let(:merchant) { merchant_and_key.first }
  let(:key) { merchant_and_key.last }
  let(:adapter) { FakePspAdapter.new }

  before { allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter) }

  def authorized_payment
    create(:payment, merchant: merchant).tap do |p|
      p.transition!(:authorized, sort_key: p.created_at + 1.second, source: "worker")
    end
  end

  def captured_payment(amount = 2500)
    authorized_payment.tap do |p|
      Ledger.record_capture!(p, amount)
      p.update_column(:captured_minor, amount)
      p.transition!(:captured, sort_key: p.created_at + 2.seconds, source: "worker")
    end
  end

  def charge(status, payment, captured_minor: 0)
    PspAdapter::Result.new(
      status: PspAdapter::Result::Status.deserialize(status.to_s), psp_reference: payment.psp_reference,
      psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: payment.created_at + 5.seconds,
      raw: { "captured_minor" => captured_minor }
    )
  end

  describe "POST /v1/payments/:id/capture" do
    it "202s, records the capture request for the full authorized amount by default, and enqueues it" do
      payment = authorized_payment

      post "/v1/payments/#{payment.id}/capture", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:accepted)
      capture = payment.captures.sole
      expect(capture).to have_attributes(amount_minor: 2500, base_captured_minor: 0, state: "pending")
      expect(CapturePaymentJob).to have_been_enqueued.with(capture.id)
    end

    it "allows one capture in flight per payment: a second gets a retriable 409 (DECISIONS #20)" do
      payment = authorized_payment
      post "/v1/payments/#{payment.id}/capture", params: { amount_minor: 1000 }.to_json, headers: auth_headers(key)

      post "/v1/payments/#{payment.id}/capture", params: { amount_minor: 500 }.to_json, headers: auth_headers(key)

      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to include("code" => "capture_in_progress", "retriable" => true)
      expect(payment.captures.count).to eq(1)
    end

    it "allows a partial capture and rejects one beyond the authorized amount" do
      payment = authorized_payment

      post "/v1/payments/#{payment.id}/capture", params: { amount_minor: 1000 }.to_json, headers: auth_headers(key)
      expect(response).to have_http_status(:accepted)

      post "/v1/payments/#{payment.id}/capture", params: { amount_minor: 9999 }.to_json, headers: auth_headers(key)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]["details"]).to have_key("amount_minor")
    end

    it "rejects capture of a pending payment with invalid_state" do
      payment = create(:payment, merchant: merchant)

      post "/v1/payments/#{payment.id}/capture", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_state")
    end
  end

  describe "several partial captures (DECISIONS #20)" do
    def capture!(payment, body)
      post "/v1/payments/#{payment.id}/capture", params: body.to_json, headers: auth_headers(key)
    end

    # Runs the capture job the API enqueued against a PSP whose running total
    # was `before` and becomes `before + amount`.
    def land_capture(payment, before:)
      capture = payment.captures.pending.sole
      adapter.script(:fetch, charge(:authorized, payment, captured_minor: before))
      adapter.script(:capture, charge(:authorized, payment, captured_minor: before + capture.amount_minor))
      CapturePaymentJob.perform_now(capture.id)
    end

    def partly_captured(amount = 1000)
      authorized_payment.tap do |p|
        capture!(p, { amount_minor: amount, final: false })
        land_capture(p, before: 0)
      end
    end

    it "TC-E3-1: a non-final partial capture leaves the payment capturable" do
      payment = partly_captured(1000)

      expect(payment.reload).to have_attributes(state: "captured", captured_minor: 1000, captures_closed_at: nil)
      expect(PaymentActions.call(payment, granted: ->(_) { true })).to include("capture" => true, "capturable_minor" => 1500)
      get "/v1/payments/#{payment.id}", headers: auth_headers(key)
      expect(json_body["amount_capturable_minor"]).to eq(1500)
    end

    it "TC-E3-2: a second capture after a non-final one is accepted and booked" do
      payment = partly_captured(1000)

      capture!(payment, { amount_minor: 1500 })
      expect(response).to have_http_status(:accepted)
      land_capture(payment, before: 1000)

      expect(Ledger.captured_minor(payment)).to eq(2500)
      expect(payment.captures.pluck(:state)).to eq(%w[succeeded succeeded])
      expect(payment.reload).to have_attributes(state: "captured")
      expect(payment.captures_closed_at).to be_present
    end

    it "TC-E3-3: a default (final) partial capture closes capturing" do
      payment = authorized_payment
      capture!(payment, { amount_minor: 1000 })
      land_capture(payment, before: 0)

      capture!(payment, { amount_minor: 500 })

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("capture_closed")
      expect(Ledger.captured_minor(payment)).to eq(1000)
    end

    it "TC-E3-4: the sum of captures can never exceed the authorized amount" do
      payment = partly_captured(1000)

      capture!(payment, { amount_minor: 2000 })

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]["details"]["amount_minor"].first).to include("between 1 and 1500")
      expect(payment.captures.pending).to be_empty
      expect(adapter.calls[:capture].size).to eq(1)
    end

    it "TC-E3-5: a zero-amount final capture closes the remainder without calling the PSP" do
      payment = partly_captured(1000)

      expect { capture!(payment, { amount_minor: 0, final: true }) }.not_to(change { payment.captures.count })

      expect(response).to have_http_status(:ok)
      expect(adapter.calls[:capture].size).to eq(1) # only the first capture
      expect(payment.reload.captures_closed_at).to be_present
      expect(json_body["amount_capturable_minor"]).to eq(0)
      event = OutboundEvent.find_by(payment: payment, event_type: "payment.captures_closed")
      expect(event.payload).to include("reason" => "merchant_request", "released_minor" => 1500)
    end

    it "TC-E3-6: a zero amount on a payment with nothing captured is refused" do
      payment = authorized_payment

      capture!(payment, { amount_minor: 0, final: true })

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_request")
      expect(json_body["error"]["message"]).to include("use cancel")
      expect(payment.reload.captures_closed_at).to be_nil
    end

    it "TC-E3-7: one capture in flight at a time still holds" do
      payment = authorized_payment
      capture!(payment, { amount_minor: 1000, final: false })

      capture!(payment, { amount_minor: 500 })

      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to include("code" => "capture_in_progress", "retriable" => true)
    end

    it "TC-E3-8: a refund between captures leaves the capturable amount alone" do
      payment = partly_captured(1000)
      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 400 }.to_json, headers: auth_headers(key)
      refund = payment.refunds.sole
      adapter.script(:refund, PspAdapter::RefundResult.new(status: PspAdapter::RefundResult::Status::Succeeded,
                                                           psp_reference: refund.psp_reference, psp_refund_id: "re_1",
                                                           failure_code: nil, psp_timestamp: payment.created_at + 6.seconds))
      RefundPaymentJob.perform_now(refund.id)
      expect(payment.reload.state).to eq("part_refunded")
      expect(PaymentActions.call(payment, granted: ->(_) { true })["capturable_minor"]).to eq(1500)

      capture!(payment, { amount_minor: 1500 })
      expect(response).to have_http_status(:accepted)
      land_capture(payment, before: 1000)

      expect(Ledger.captured_minor(payment)).to eq(2500)
      expect(Ledger.refunded_minor(payment)).to eq(400)
      expect(Ledger.balances(merchant)).to eq("EUR" => 2100)
    end

    it "TC-E3-10: a non-final capture is refused on a PSP without multicapture" do
      kiripay = FakePspAdapter.new(name: "kiripay", currencies: %w[VND], multicapture: false)
      allow(PspRouter).to receive(:adapter).with("kiripay").and_return(kiripay)
      payment = create(:payment, :vnd, merchant: merchant).tap do |p|
        p.transition!(:authorized, sort_key: p.created_at + 1.second, source: "worker")
      end

      capture!(payment, { final: false })

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("multicapture_unsupported")
    end

    it "TC-E3-11: at most 50 non-final captures, and a final one is still allowed after them" do
      payment = create(:payment, merchant: merchant, amount_minor: 10_000).tap do |p|
        p.transition!(:authorized, sort_key: p.created_at + 1.second, source: "worker")
      end
      50.times do |i|
        payment.captures.create!(amount_minor: 10, base_captured_minor: i * 10, final: false, state: "succeeded")
      end
      Ledger.record_capture!(payment, 500)

      capture!(payment, { amount_minor: 10, final: false })
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]["code"]).to eq("capture_limit_reached")

      capture!(payment, { amount_minor: 10 })
      expect(response).to have_http_status(:accepted)
    end

    it "refuses a `final` that is not a boolean" do
      capture!(authorized_payment, { amount_minor: 1000, final: "no" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]["details"]).to have_key("final")
    end

    it "TC-E3-17: cancel after a partial capture is refused, with a hint" do
      payment = partly_captured(1000)

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_state")
      expect(json_body["error"]["message"]).to include("zero-amount final capture")
    end
  end

  describe "POST /v1/payments/:id/cancel" do
    it "voids synchronously and returns the canceled payment with history" do
      payment = authorized_payment
      adapter.script(:cancel, charge(:canceled, payment))

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:ok)
      expect(json_body["state"]).to eq("canceled")
      expect(json_body["transitions"].last["to"]).to eq("canceled")
    end

    it "is only valid from authorized" do
      payment = captured_payment

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_state")
      expect(payment.reload.state).to eq("captured")
    end

    it "on timeout, fetches; if still authorized answers 503 retriable and leaves state untouched" do
      payment = authorized_payment
      adapter.script(:cancel, PspAdapter::TimedOut)
      adapter.script(:fetch, charge(:authorized, payment))

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:service_unavailable)
      expect(json_body["error"]["retriable"]).to be true
      expect(payment.reload.state).to eq("authorized")
    end
  end

  describe "POST /v1/payments/:id/refunds" do
    it "202s a pending refund, reserves the amount, and enqueues the PSP call" do
      payment = captured_payment

      expect do
        post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 500, reason: "damaged" }.to_json,
                                                    headers: auth_headers(key)
      end.to have_enqueued_job(RefundPaymentJob)

      expect(response).to have_http_status(:accepted)
      expect(json_body).to include("state" => "pending", "amount_minor" => 500, "reason" => "damaged")
      expect(json_body["psp_reference"]).to start_with("phr_")
    end

    it "counts pending refunds as reserved, so two partials cannot together exceed the capture" do
      payment = captured_payment(2500)

      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 2000 }.to_json, headers: auth_headers(key)
      expect(response).to have_http_status(:accepted)

      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 1000 }.to_json, headers: auth_headers(key)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]["details"]["amount_minor"].first).to include("pending 2000")
    end

    it "rejects a refund of an authorized-but-uncaptured payment" do
      payment = authorized_payment

      post "/v1/payments/#{payment.id}/refunds", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_state")
    end

    it "rejects a partial refund when the adapter only supports full refunds (Kiripay semantics)" do
      payment = captured_payment
      allow(PspRouter).to receive(:adapter).with("nordpay").and_return(FakePspAdapter.new(partial_refund: false))

      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 500 }.to_json, headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("partial_refund_unsupported")
    end
  end

  describe "a cancel the PSP refuses (bug 6)" do
    it "TC-G6-1: refuses a Kiripay cancel up front, with no PSP call" do
      kiripay = FakePspAdapter.new(name: "kiripay", currencies: %w[VND], void: false)
      allow(PspRouter).to receive(:adapter).with("kiripay").and_return(kiripay)
      payment = create(:payment, :vnd, merchant: merchant).tap do |p|
        p.transition!(:authorized, sort_key: p.created_at + 1.second, source: "worker")
      end

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("cancel_unsupported")
      expect(kiripay.calls[:cancel]).to be_empty
      expect(KiripayAdapter.new.supports_void?).to be(false)
      expect(NordpayAdapter.new.supports_void?).to be(true)
    end

    it "TC-G6-2: a PSP 409 not_voidable becomes a 409 psp_rejected, and the payment is unchanged" do
      payment = authorized_payment
      adapter.script(:cancel, PspAdapter::Rejected.new(409, "nordpay 409: not_voidable"))

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to include("code" => "psp_rejected", "retriable" => false)
      expect(payment.reload.state).to eq("authorized")
    end
  end

  describe "when the PSP cannot be reached" do
    it "answers a synchronous cancel with a retriable 503, not a 500, and leaves the payment untouched" do
      payment = authorized_payment
      adapter.script(:cancel, PspCircuit::Open.new("nordpay circuit open"))

      post "/v1/payments/#{payment.id}/cancel", params: "{}", headers: auth_headers(key)

      expect(response).to have_http_status(:service_unavailable)
      expect(json_body["error"]).to include("code" => "psp_unavailable", "retriable" => true)
      expect(payment.reload.state).to eq("authorized")
    end
  end

  describe "GET /v1/balance" do
    it "derives per-currency balances from the ledger" do
      captured_payment(2500)
      vnd = create(:payment, :vnd, merchant: merchant)
      Ledger.record_capture!(vnd, 500_000)

      get "/v1/balance", headers: auth_headers(key)

      expect(response).to have_http_status(:ok)
      expect(json_body["available"]).to contain_exactly(
        { "currency" => "EUR", "amount_minor" => 2500, "display_amount" => "25.00" },
        { "currency" => "VND", "amount_minor" => 500_000, "display_amount" => "500000" }
      )
      expect(json_body["pending"]).to eq([])
    end

    it "moves a requested refund from available to pending until the PSP confirms it" do
      payment = captured_payment(2500)
      post "/v1/payments/#{payment.id}/refunds", params: { amount_minor: 500 }.to_json, headers: auth_headers(key)

      get "/v1/balance", headers: auth_headers(key)

      expect(json_body["available"]).to eq([{ "currency" => "EUR", "amount_minor" => 2000, "display_amount" => "20.00" }])
      expect(json_body["pending"]).to eq([{ "currency" => "EUR", "amount_minor" => 500, "display_amount" => "5.00" }])
    end
  end
end
