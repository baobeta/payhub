require "rails_helper"

RSpec.describe "Observability: /metrics, /healthz, and one JSON line per request and per job", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key }
  let(:merchant) { merchant_and_key.first }
  let(:key) { merchant_and_key.last }

  def capture_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end

  it "GET /healthz is 200 and GET /metrics exposes the counters and gauges in Prometheus text format" do
    post "/v1/payments", params: { amount_minor: 2500, currency: "EUR", payment_method_token: "tok" }.to_json,
                         headers: auth_headers(key)

    get "/healthz"
    expect(response).to have_http_status(:ok)

    get "/metrics"
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with("text/plain")
    expect(response.body).to include('payhub_payments_created_total{psp="nordpay",currency="EUR"}')
    expect(response.body).to include("payhub_unknown_state_payments 0")
    expect(response.body).to match(/payhub_outbound_events_pending \d+/)
  end

  it "traces the synchronous payment creation boundary" do
    allow(Tracing).to receive(:in_span).and_call_original

    post "/v1/payments", params: { amount_minor: 2500, currency: "EUR", payment_method_token: "tok" }.to_json,
                         headers: auth_headers(key)

    expect(Tracing).to have_received(:in_span).with(
      "payhub.payment.create",
      attributes: hash_including("payhub.merchant_id" => merchant.id, "payhub.psp_name" => "nordpay",
                                 "payhub.operation" => "create_payment")
    )
  end

  it "logs one JSON line per request carrying correlation IDs and payment context" do
    payment = create(:payment, merchant: merchant)
    log = capture_log { get "/v1/payments/#{payment.id}", headers: auth_headers(key) }

    line = log.lines.map(&:strip).find { |l| l.start_with?("{") && l.include?('"kind":"request"') }
    expect(line).to be_present, "no request log line in: #{log}"
    parsed = JSON.parse(line)
    expect(parsed).to include("kind" => "request", "merchant_id" => merchant.id, "payment_id" => payment.id,
                              "method" => "GET", "status" => 200,
                              "trace_id" => a_string_matching(/\A[0-9a-f]{32}\z/),
                              "span_id" => a_string_matching(/\A[0-9a-f]{16}\z/))
    expect(parsed["request_id"]).to be_present
    expect(parsed["duration_ms"]).to be_a(Numeric)
    expect(parsed).not_to have_key("params") # bodies are never logged
  end

  it "logs one JSON line per job with the same keys, joined to the originating request by request_id" do
    allow(PspRouter).to receive(:adapter).and_return(FakePspAdapter.new.tap { |a| a.script(:authorize, -> { raise "unused" }) })
    log = capture_log do
      post "/v1/payments", params: { amount_minor: 2500, currency: "EUR", payment_method_token: "tok" }.to_json,
                           headers: auth_headers(key)
      # Give the job a real answer now that we know the payment.
      payment = Payment.last
      PspRouter.adapter("nordpay").instance_variable_get(:@scripts)[:authorize] = [
        PspAdapter::Result.new(status: PspAdapter::Result::Status::Authorized, psp_reference: payment.psp_reference,
                               psp_charge_id: "ch", decline_code: nil, psp_timestamp: payment.created_at + 1)
      ]
      perform_enqueued_jobs
    end

    lines = log.lines.map(&:strip).select { |l| l.start_with?("{") }.map { |l| JSON.parse(l) rescue nil }.compact
    request_line = lines.find { |l| l["kind"] == "request" && l["method"] == "POST" }
    job_line = lines.find { |l| l["kind"] == "job" && l["job"] == "AuthorizePaymentJob" }

    expect(request_line).to be_present
    expect(job_line).to be_present
    expect(job_line).to include("payment_id" => Payment.last.id, "merchant_id" => merchant.id, "psp_name" => "nordpay",
                                "trace_id" => a_string_matching(/\A[0-9a-f]{32}\z/),
                                "span_id" => a_string_matching(/\A[0-9a-f]{16}\z/))
    expect(job_line["duration_ms"]).to be_a(Numeric)
    # The join: grep on either id finds both lines.
    expect(job_line["request_id"]).to eq(request_line["request_id"])
    expect(job_line["trace_id"]).to eq(request_line["trace_id"])
  end
end
