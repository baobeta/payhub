# typed: strict
# frozen_string_literal: true

# Applies one verified, deduplicated inbound webhook to its payment.
#
# Ordering is the PSP's timestamp, not arrival (DECISIONS #4): transition!
# records-without-applying anything older than the current row. Lag between
# the PSP's clock and ours is logged, never used for ordering.
#
# For a capture-only PSP (Kiripay) this is where money gets booked: the
# customer approved in their wallet, the PSP told us, and BookCapture writes
# the ledger from the PSP's reported amount.
class ProcessInboundEventJob < ApplicationJob
  extend T::Sig

  queue_as :webhooks

  # States where money has already been captured: a PSP report there books
  # progress and never moves the payment back to authorized.
  CAPTURED_STATES = %w[captured part_refunded refunded].freeze
  # The inbound_events.error prefix OpsQueue looks for.
  LATE_SUCCESS = "late_success_after_failure"

  sig { params(inbound_event_id: String).void }
  def perform(inbound_event_id)
    event = InboundEvent.find(inbound_event_id)
    return if event.processed? || !event.signature_valid

    payment = Payment.find_by(psp_name: event.psp_name, psp_reference: event.psp_reference)
    unless payment
      # Arrived before our worker wrote the payment row, or references a
      # charge we never made. Leave unprocessed; the sweeper retries it.
      Rails.logger.warn({ event: "webhook.orphan", psp_name: event.psp_name, psp_reference: event.psp_reference }.to_json)
      return
    end

    # Signature was verified once, at receipt; here we only re-parse the stored payload.
    parsed = PspRouter.adapter(event.psp_name).parse_webhook(T.cast(event.payload, T::Hash[String, T.untyped]))

    return late_success(payment, event, parsed) if late_success?(payment, parsed)

    begin
      apply(payment, event, parsed)
      event.update!(processed_at: Time.current)
    rescue PaymentStateMachine::IllegalTransition => e
      # A genuinely impossible edge (e.g. captured → pending). Not stale — stale
      # is handled inside transition!. Record and stop; a human looks at it.
      event.update!(processed_at: Time.current, error: e.message)
      Rails.logger.error({ event: "webhook.illegal_transition", inbound_event_id: event.id, detail: e.message }.to_json)
    end
  end

  private

  sig { params(payment: Payment, event: InboundEvent, parsed: PspAdapter::WebhookEvent).void }
  def apply(payment, event, parsed)
    status = parsed.status
    return unless status

    ts = parsed.psp_timestamp
    lag_ms = ((event.received_at - ts) * 1000).round
    meta = { "inbound_event_id" => event.id, "psp_charge_id" => parsed.psp_charge_id, "lag_ms" => lag_ms }
    Rails.logger.info({ event: "webhook.apply", payment_id: payment.id, type: event.event_type, lag_ms: lag_ms }.to_json)

    case status
    when PspAdapter::Result::Status::RequiresAction
      move(payment, :requires_action, ts, meta)
    when PspAdapter::Result::Status::Authorized
      # Nordpay reports a partial capture as a charge still `authorized`, with
      # its running total (DECISIONS #20). On a payment already past
      # authorized that is progress to book, not a move back.
      move(payment, :authorized, ts, meta) unless CAPTURED_STATES.include?(payment.reload.state)
      captured = parsed.captured_minor.to_i
      BookCapture.call(payment, psp_captured_minor: captured, psp_timestamp: ts, source: "webhook", metadata: meta) if captured.positive?
    when PspAdapter::Result::Status::Captured
      # Capture-only PSPs skip `authorized` on the wire; our model does not.
      unless (CAPTURED_STATES + ["authorized"]).include?(payment.reload.state)
        move(payment, :authorized, ts - 0.001, meta)
      end
      # Book the PSP's own running total (#20); a PSP that reports none
      # (Kiripay) only ever captures the full amount.
      BookCapture.call(payment, psp_captured_minor: parsed.captured_minor || payment.amount_minor, psp_timestamp: ts,
                                source: "webhook", metadata: meta)
    when PspAdapter::Result::Status::Canceled
      move(payment, :canceled, ts, meta)
    when PspAdapter::Result::Status::Declined
      move(payment, :failed, ts, meta.merge("decline_code" => parsed.decline_code))
    when PspAdapter::Result::Status::NotFound
      nil
    else
      T.absurd(status)
    end
  end

  # The PSP says the charge succeeded, but we already failed the payment
  # locally (an abandoned wallet payment we expired). The customer may have
  # paid for an order the merchant was told is dead. `failed` is terminal, so
  # nothing is booked or moved: the event is kept with an error, and the
  # payment waits in the ops queue for a human to refund it.
  sig { params(payment: Payment, parsed: PspAdapter::WebhookEvent).returns(T::Boolean) }
  def late_success?(payment, parsed)
    payment.state == "failed" &&
      [PspAdapter::Result::Status::Authorized, PspAdapter::Result::Status::Captured].include?(parsed.status)
  end

  sig { params(payment: Payment, event: InboundEvent, parsed: PspAdapter::WebhookEvent).void }
  def late_success(payment, event, parsed)
    status = T.must(parsed.status).serialize
    event.update!(processed_at: Time.current, error: "#{LATE_SUCCESS}: PSP reports #{status} on a failed payment")
    Metrics.increment(:late_success, psp: event.psp_name)
    Rails.logger.error({ event: "webhook.#{LATE_SUCCESS}", inbound_event_id: event.id, payment_id: payment.id,
                         psp_name: event.psp_name, psp_status: status }.to_json)
  end

  # Same tolerance as AuthorizePaymentJob#move: already-there is not an error.
  sig do
    params(payment: Payment, to: Symbol, sort_key: T.any(Time, ActiveSupport::TimeWithZone),
           metadata: T::Hash[String, T.untyped]).void
  end
  def move(payment, to, sort_key, metadata)
    payment.transition!(to, sort_key: sort_key, source: "webhook", metadata: metadata)
  rescue PaymentStateMachine::IllegalTransition
    raise unless payment.reload.state == to.to_s
  end
end
