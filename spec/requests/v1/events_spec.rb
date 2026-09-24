require "rails_helper"

RSpec.describe "Outbound events: outbox, delivery, GET /v1/events, redeliver", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key(webhook_url: "https://merchant.test/hooks") }
  let(:merchant) { merchant_and_key.first }
  let(:key) { merchant_and_key.last }

  describe "the transactional outbox" do
    it "writes an OutboundEvent in the same transaction as every state change" do
      payment = create(:payment, merchant: merchant)
      expect(merchant.outbound_events.pluck(:event_type)).to eq(%w[payment.created])

      payment.transition!(:authorized, sort_key: payment.created_at + 1, source: "worker")
      expect(merchant.outbound_events.order(:created_at).pluck(:event_type)).to eq(%w[payment.created payment.authorized])
      expect(merchant.outbound_events.last.payload).to include("id" => payment.id, "state" => "authorized")
    end

    it "does not write the event if the state change rolls back" do
      payment = create(:payment, merchant: merchant)
      expect do
        Payment.transaction do
          payment.transition!(:authorized, sort_key: payment.created_at + 1, source: "worker")
          raise ActiveRecord::Rollback
        end
      end.not_to change { merchant.outbound_events.count }
    end

    it "is born delivered for a merchant with no webhook_url — queryable, nothing to send" do
      quiet, = create_merchant_with_key(webhook_url: nil)
      create(:payment, merchant: quiet)
      expect(quiet.outbound_events.first).to have_attributes(state: "delivered", attempts: 0)
    end
  end

  describe "delivery tracing" do
    let(:tracer) { OpenTelemetry.tracer_provider.tracer("spec") }

    it "records the trace an event was emitted in" do
      origin = tracer.in_span("origin") do |span|
        create(:payment, merchant: merchant)
        span.context
      end
      expect(merchant.outbound_events.first.traceparent).to include(origin.hex_trace_id)
    end

    it "delivers each event in its own span, linked back to the trace that emitted it" do
      origin = tracer.in_span("origin") do |span|
        create(:payment, merchant: merchant)
        span.context
      end
      stub_request(:post, "https://merchant.test/hooks").to_return(status: 200)

      DeliverOutboundEventsJob.perform_now

      span = SPAN_EXPORTER.finished_spans.find { |s| s.name == "payhub.webhook.deliver" }
      expect(span.links.map { |l| l.span_context.hex_trace_id }).to eq([origin.hex_trace_id])
      expect(span.hex_trace_id).not_to eq(origin.hex_trace_id) # its own trace, not the emitter's
      expect(span.attributes).to include("payhub.outbound_event_id" => merchant.outbound_events.first.id,
                                         "payhub.merchant_id" => merchant.id, "payhub.attempt" => 1,
                                         "payhub.outcome" => "delivered")
    end

    it "still delivers events stored before traceparent existed, without a link" do
      create(:payment, merchant: merchant)
      merchant.outbound_events.update_all(traceparent: nil)
      stub_request(:post, "https://merchant.test/hooks").to_return(status: 200)

      DeliverOutboundEventsJob.perform_now

      span = SPAN_EXPORTER.finished_spans.find { |s| s.name == "payhub.webhook.deliver" }
      expect(span.links).to be_blank
    end
  end

  describe DeliverOutboundEventsJob do
    before { create(:payment, merchant: merchant) } # emits payment.created into the outbox

    let(:event) { merchant.outbound_events.first }

    it "POSTs a signed envelope, records the attempt, marks delivered on 2xx" do
      stub = stub_request(:post, "https://merchant.test/hooks").to_return(status: 200)

      described_class.perform_now

      expect(stub).to have_been_requested.once
      expect(event.reload).to have_attributes(state: "delivered", attempts: 1)
      expect(event.delivery_attempts.map(&:response_status)).to eq([200])
      req = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.first
      ts, v1 = req.headers["X-Payhub-Signature"].scan(/t=(\d+),v1=(\h+)/).first
      expect(v1).to eq(OpenSSL::HMAC.hexdigest("SHA256", merchant.webhook_secret, "#{ts}.#{req.body}"))
      expect(JSON.parse(req.body)).to include("type" => "payment.created", "attempt" => 1)
    end

    it "backs off on failure and dead-letters after MAX_ATTEMPTS, one attempt row per try" do
      stub_request(:post, "https://merchant.test/hooks").to_return(status: 503)

      described_class.perform_now
      expect(event.reload).to have_attributes(state: "pending", attempts: 1, last_error: "HTTP 503")
      expect(event.next_attempt_at).to be > Time.current + 50.seconds

      (OutboundEvent::MAX_ATTEMPTS - 1).times do
        event.update_column(:next_attempt_at, 1.second.ago)
        described_class.perform_now
      end
      expect(event.reload).to have_attributes(state: "dead", attempts: OutboundEvent::MAX_ATTEMPTS)
      expect(event.delivery_attempts.count).to eq(OutboundEvent::MAX_ATTEMPTS)
    end

    it "treats a connection failure as a failed attempt, never raises out of the sweeper" do
      stub_request(:post, "https://merchant.test/hooks").to_raise(Faraday::ConnectionFailed.new("refused"))

      expect { described_class.perform_now }.not_to raise_error
      expect(event.reload.last_error).to include("ConnectionFailed")
    end

    it "does not double-send when two sweepers run at once (SKIP LOCKED)", :concurrency do
      merchant2, = create_merchant_with_key(webhook_url: "https://merchant.test/hooks")
      create(:payment, merchant: merchant2)
      stub = stub_request(:post, "https://merchant.test/hooks").to_return { sleep 0.1; { status: 200 } }

      pending_before = OutboundEvent.where(state: "pending").count # both merchants' events → 2
      threads = 3.times.map do
        Thread.new { ActiveRecord::Base.connection_pool.with_connection { described_class.perform_now } }
      end
      threads.each(&:join)

      # 3 sweepers, N events, exactly N requests: SKIP LOCKED partitioned the work.
      expect(stub).to have_been_requested.times(pending_before)
      expect(OutboundEvent.where(state: "pending").count).to eq(0)
    end
  end

  describe "GET /v1/events" do
    it "lists newest first with delivery attempts, filters by state, paginates by cursor" do
      3.times { create(:payment, merchant: merchant) }
      stub_request(:post, "https://merchant.test/hooks").to_return(status: 200)
      DeliverOutboundEventsJob.perform_now

      get "/v1/events", params: { limit: 2 }, headers: auth_headers(key)
      expect(response).to have_http_status(:ok)
      expect(json_body["data"].size).to eq(2)
      expect(json_body["has_more"]).to be true
      expect(json_body["data"].first["delivery_attempts"].first).to include("attempt" => 1, "response_status" => 200)

      get "/v1/events", params: { limit: 2, cursor: json_body["next_cursor"] }, headers: auth_headers(key)
      expect(json_body["data"].size).to eq(1)
      expect(json_body["has_more"]).to be false
    end

    it "filters by state" do
      create(:payment, merchant: merchant)
      get "/v1/events", params: { state: "dead" }, headers: auth_headers(key)
      expect(json_body["data"]).to be_empty
      get "/v1/events", params: { state: "pending" }, headers: auth_headers(key)
      expect(json_body["data"].size).to eq(1)
    end
  end

  describe "POST /v1/events/:id/redeliver" do
    it "moves a dead event back to pending and enqueues delivery; refuses a non-dead one" do
      create(:payment, merchant: merchant)
      event = merchant.outbound_events.first
      event.update!(state: "dead", attempts: 8, last_error: "HTTP 503")

      expect do
        post "/v1/events/#{event.id}/redeliver", params: "{}", headers: auth_headers(key)
      end.to have_enqueued_job(DeliverOutboundEventsJob)
      expect(response).to have_http_status(:accepted)
      expect(event.reload).to have_attributes(state: "pending", last_error: nil)

      post "/v1/events/#{event.id}/redeliver", params: "{}", headers: auth_headers(key)
      expect(response).to have_http_status(:bad_request)
      expect(json_body["error"]["code"]).to eq("invalid_state")
    end
  end
end
