require "rails_helper"

RSpec.describe NordpayAdapter do
  subject(:adapter) { described_class.new(base_url: "http://nordpay.test", api_key: "np_test_key") }

  let(:payment) { create(:payment, psp_reference: "ph_abc123") }
  let(:charge) do
    { "id" => "ch_1", "reference" => "ph_abc123", "status" => "authorized",
      "amount_minor" => 2500, "currency" => "EUR", "created_at" => "2026-01-01T10:00:00.123Z" }
  end

  def stub_charge(response_body, status: 200)
    stub_request(:post, "http://nordpay.test/charges")
      .with(headers: { "Authorization" => "Bearer np_test_key", "X-Request-Id" => "ph_abc123" },
            body: hash_including("amount_minor" => 2500, "currency" => "EUR"))
      .to_return(status: status, body: response_body.to_json, headers: { "Content-Type" => "application/json" })
  end

  describe "#authorize" do
    it "sends psp_reference as X-Request-Id and maps an authorized charge" do
      stub_charge(charge)

      result = adapter.authorize(payment)

      expect(result.status).to eq(PspAdapter::Result::Status::Authorized)
      expect(result.psp_charge_id).to eq("ch_1")
      expect(result.psp_timestamp).to eq(Time.utc(2026, 1, 1, 10, 0, 0, 123_000))
    end

    it "treats HTTP 200 + status declined as a Declined result, not a success" do
      stub_charge(charge.merge("status" => "declined", "code" => "insufficient_funds"))

      result = adapter.authorize(payment)

      expect(result.status).to eq(PspAdapter::Result::Status::Declined)
      expect(result.decline_code).to eq("insufficient_funds")
    end

    it "dedupes a duplicated charge in the response body on reference" do
      stub_charge({ "charges" => [charge, charge] })

      expect(adapter.authorize(payment).psp_charge_id).to eq("ch_1")
    end

    it "raises TimedOut on a READ timeout — the request MAY have landed" do
      stub_request(:post, "http://nordpay.test/charges").to_raise(Net::ReadTimeout)

      expect { adapter.authorize(payment) }.to raise_error(PspAdapter::TimedOut)
    end

    it "raises Unavailable on an OPEN timeout — we never connected, so nothing landed" do
      stub_request(:post, "http://nordpay.test/charges").to_timeout # WebMock: Net::OpenTimeout

      expect { adapter.authorize(payment) }.to raise_error(PspAdapter::Unavailable)
    end

    it "raises Unavailable on 5xx and connection failure — safe to retry with the same reference" do
      stub_charge({ "error" => { "message" => "boom" } }, status: 500)
      expect { adapter.authorize(payment) }.to raise_error(PspAdapter::Unavailable, /500/)

      stub_request(:post, "http://nordpay.test/charges").to_raise(Faraday::ConnectionFailed.new("refused"))
      expect { adapter.authorize(payment) }.to raise_error(PspAdapter::Unavailable, /unreachable/)
    end

    it "raises Rejected on a 4xx — our bug, retrying cannot help" do
      stub_charge({ "error" => { "message" => "bad currency" } }, status: 422)

      expect { adapter.authorize(payment) }.to raise_error(PspAdapter::Rejected) { |e| expect(e.http_status).to eq(422) }
    end
  end

  describe "#fetch" do
    it "returns the charge's current status" do
      stub_request(:get, "http://nordpay.test/charges/ph_abc123")
        .to_return(status: 200, body: charge.merge("status" => "captured").to_json,
                   headers: { "Content-Type" => "application/json" })

      expect(adapter.fetch("ph_abc123").status).to eq(PspAdapter::Result::Status::Captured)
    end

    it "returns NotFound on 404 — the PSP never saw our request" do
      stub_request(:get, "http://nordpay.test/charges/ph_abc123")
        .to_return(status: 404, body: { error: { message: "nope" } }.to_json,
                   headers: { "Content-Type" => "application/json" })

      expect(adapter.fetch("ph_abc123")).to be_not_found
    end
  end

  it "declares its capabilities" do
    expect(adapter.currencies).to eq(%w[EUR GBP USD])
    expect(adapter.supports_partial_refund?).to be true
    expect(adapter.separate_authorize_and_capture?).to be true
  end

  describe "#verify_webhook" do
    let(:body) { { "id" => "evt_1", "type" => "charge.captured", "created_at" => "2026-01-01T10:01:00.000Z", "data" => charge.merge("status" => "captured") }.to_json }

    def signed(secret) = { "X-Nordpay-Signature" => OpenSSL::HMAC.hexdigest("SHA256", secret, body) }

    it "accepts a body signed with the configured secret and normalises it" do
      event = adapter.verify_webhook(body, signed("np_whsec_test"))
      expect(event).to have_attributes(external_id: "evt_1", status: PspAdapter::Result::Status::Captured)
    end

    it "rejects a wrong secret and a missing header" do
      expect { adapter.verify_webhook(body, signed("wrong")) }.to raise_error(PspAdapter::InvalidSignature, /mismatch/)
      expect { adapter.verify_webhook(body, {}) }.to raise_error(PspAdapter::InvalidSignature, /missing/)
    end

    it "accepts both secrets while rotating (DECISIONS #15)" do
      rotating = described_class.new(base_url: "http://nordpay.test", api_key: "np_test_key", webhook_secrets: %w[np_new np_whsec_test])
      expect(rotating.verify_webhook(body, signed("np_whsec_test")).external_id).to eq("evt_1")
      expect(rotating.verify_webhook(body, signed("np_new")).external_id).to eq("evt_1")
    end
  end

  describe "circuit breaker (DECISIONS #17)" do
    it "refuses before sending once the PSP keeps failing, so a refused authorize can never be ambiguous" do
      stub = stub_request(:get, %r{nordpay.test/charges/}).to_return(status: 503, body: "{}")
      10.times { adapter.fetch("ph_x") rescue PspAdapter::Unavailable }
      expect(stub).to have_been_requested.times(10)

      charge_stub = stub_request(:post, "http://nordpay.test/charges")
      expect { adapter.authorize(create(:payment)) }.to raise_error(PspCircuit::Open)
      expect(charge_stub).not_to have_been_requested
    end
  end

  describe "#settlement_report" do
    it "parses the day's CSV into settlement lines keyed by our references" do
      csv = <<~CSV
        line_id,type,reference,refund_reference,gross_minor,fee_minor,net_minor,currency,booked_at
        stl_1,capture,ph_a,,6000,109,5891,EUR,2026-09-23T10:00:00.000Z
        stl_2,refund,ph_a,phr_b,2500,0,-2500,EUR,2026-09-23T11:00:00.000Z
      CSV
      stub_request(:get, "http://nordpay.test/settlements?date=2026-09-23").to_return(status: 200, body: csv, headers: { "Content-Type" => "text/csv" })

      lines = adapter.settlement_report(Date.new(2026, 9, 23))

      expect(lines.map { |l| [l.kind, l.psp_reference, l.refund_reference, l.gross_minor, l.fee_minor, l.net_minor] })
        .to eq([["capture", "ph_a", nil, 6000, 109, 5891], ["refund", "ph_a", "phr_b", 2500, 0, -2500]])
    end

    it "treats an unreadable report as the PSP's error, not ours to guess at" do
      stub_request(:get, %r{nordpay.test/settlements}).to_return(status: 200, body: "line_id\nstl_1\n", headers: { "Content-Type" => "text/csv" })
      expect { adapter.settlement_report(Date.new(2026, 9, 23)) }.to raise_error(PspAdapter::Rejected, /unreadable/)
    end
  end
end
