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
end
