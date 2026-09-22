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
      move(payment, :authorized, ts, meta)
    when PspAdapter::Result::Status::Captured
      # Capture-only PSPs skip `authorized` on the wire; our model does not.
      unless %w[authorized captured part_refunded refunded].include?(payment.reload.state)
        move(payment, :authorized, ts - 0.001, meta)
      end
      # Kiripay always captures the full amount.
      BookCapture.call(payment, psp_captured_minor: payment.amount_minor, psp_timestamp: ts, source: "webhook", metadata: meta)
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
