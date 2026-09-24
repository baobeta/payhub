# typed: strict
# frozen_string_literal: true

# The outbox sweeper. Runs every minute: delivers every due OutboundEvent to
# its merchant's webhook_url, records one OutboundDeliveryAttempt per try,
# backs off exponentially, and dead-letters after MAX_ATTEMPTS.
#
# Two sweepers may run at once (scaled Sidekiq). Each row is claimed with
# FOR UPDATE SKIP LOCKED, so they partition the work instead of double-sending.
class DeliverOutboundEventsJob < ApplicationJob
  extend T::Sig

  queue_as :sweepers

  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5
  BATCH = 100

  sig { params(limit: Integer).void }
  def perform(limit = BATCH)
    ids = OutboundEvent.due.limit(limit).pluck(:id)
    ids.each { |id| deliver_one(id) }

    Metrics.gauge(:outbound_events_pending, OutboundEvent.where(state: "pending").count)
    Metrics.gauge(:outbound_events_dead, OutboundEvent.where(state: "dead").count)
  end

  sig { params(event_id: String).void }
  def self.deliver_now(event_id) = new.send(:deliver_one, event_id)

  private

  sig { params(event_id: String).void }
  def deliver_one(event_id)
    event = T.let(nil, T.nilable(OutboundEvent))
    OutboundEvent.transaction do
      event = OutboundEvent.lock("FOR UPDATE SKIP LOCKED").find_by(id: event_id, state: "pending")
      return unless event # another sweeper has it, or it was delivered meanwhile

      # One span per delivery, linked (not parented) to the trace that emitted
      # the event: this batch serves many origins, and a span has one parent.
      Tracing.in_span("payhub.webhook.deliver", links: Tracing.links_from(event.traceparent), attributes: {
        "payhub.outbound_event_id" => event.id, "payhub.event_type" => event.event_type,
        "payhub.merchant_id" => event.merchant_id, "payhub.payment_id" => event.payment_id,
        "payhub.attempt" => event.attempts + 1
      }) do |span|
        span.set_attribute("payhub.outcome", attempt_delivery(event))
      end
    end
  end

  # Returns the outcome: "delivered", "retry", or "dead".
  sig { params(event: OutboundEvent).returns(String) }
  def attempt_delivery(event)
    attempt_number = event.attempts + 1
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, error = post(event)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    OutboundDeliveryAttempt.create!(outbound_event: event, attempt_number: attempt_number,
                                    response_status: status, error: error, duration_ms: duration_ms)
    Metrics.increment(:webhook_deliveries, attempt: attempt_number.to_s)

    if status && status.between?(200, 299)
      event.update!(state: "delivered", attempts: attempt_number, delivered_at: Time.current, last_error: nil)
      "delivered"
    elsif attempt_number >= OutboundEvent::MAX_ATTEMPTS
      event.update!(state: "dead", attempts: attempt_number, last_error: error || "HTTP #{status}")
      Rails.logger.error({ event: "outbound.dead_letter", outbound_event_id: event.id, merchant_id: event.merchant_id,
                           type: event.event_type, attempts: attempt_number }.to_json)
      "dead"
    else
      event.update!(attempts: attempt_number, last_error: error || "HTTP #{status}",
                    next_attempt_at: Time.current + OutboundEvent::BACKOFF.call(attempt_number))
      "retry"
    end
  end

  # Returns [http_status, error_message]. Never raises: a merchant's broken
  # endpoint must not take the sweeper down with it.
  sig { params(event: OutboundEvent).returns([T.nilable(Integer), T.nilable(String)]) }
  def post(event)
    merchant = T.must(event.merchant)
    body = JSON.generate(event.envelope)
    ts = Time.current.to_i
    signature = WebhookSignature.header(body, secrets: merchant.webhook_signing_secrets, at: ts)

    response = Faraday.new(url: T.must(merchant.webhook_url)) do |f|
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout = READ_TIMEOUT
      f.adapter Faraday.default_adapter
    end.post(nil, body, { "Content-Type" => "application/json", "X-Payhub-Signature" => signature,
                          "X-Payhub-Event-Id" => event.id })
    [response.status, nil]
  rescue Faraday::Error, SystemCallError, IOError => e
    [nil, "#{e.class}: #{e.message}"[0, 500]]
  end
end
