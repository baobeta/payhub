# typed: true
# frozen_string_literal: true

# Transactional outbox: created in the same DB transaction as the state change
# it announces, delivered later by DeliverOutboundEventsJob with backoff.
class OutboundEvent < ApplicationRecord
  extend T::Sig

  belongs_to :merchant
  belongs_to :payment, optional: true
  has_many :delivery_attempts, -> { order(:attempt_number) },
           class_name: "OutboundDeliveryAttempt", dependent: :restrict_with_exception

  STATES = %w[pending delivered dead].freeze
  # Wait after failed attempt n of a delivery budget (TEST_CASES H8). Attempt 8
  # is the last: dead about 70.6h after the first try, Stripe's "about 3 days"
  # (https://docs.stripe.com/webhooks). The first waits are short for a blip;
  # the long tail outlasts a merchant's weekend outage. DECISIONS #4, corollary.
  BACKOFF_SCHEDULE = T.let([1.minute, 5.minutes, 30.minutes, 2.hours, 8.hours, 24.hours, 36.hours].freeze,
                           T::Array[ActiveSupport::Duration])
  MAX_ATTEMPTS = BACKOFF_SCHEDULE.size + 1

  validates :event_type, :payload, presence: true
  validates :state, inclusion: { in: STATES }

  scope :due, -> { where(state: "pending").where(next_attempt_at: ..Time.current).order(:next_attempt_at) }

  # Called INSIDE the caller's transaction (Payment#transition!, refund jobs).
  # A merchant with no webhook_url still gets the event — it is queryable via
  # GET /v1/events — but nothing is delivered, so it is born delivered.
  #
  # `sequence` counts the payment's events, from 1, in the order they commit
  # (Adyen's sequenceNumber): max + 1 under the payment's row lock. Every
  # caller already holds that lock (Payment#transition!, the capture and refund
  # jobs); taking it again here is free in the same transaction and keeps
  # emit! correct on its own. The unique index is the backstop.
  sig { params(payment: Payment, event_type: String, extra: T::Hash[String, T.untyped]).returns(OutboundEvent) }
  def self.emit!(payment, event_type, extra = {})
    merchant = T.must(payment.merchant)
    deliverable = merchant.webhook_url.present?
    Payment.where(id: payment.id).lock.pick(:id) # not payment.lock!: that reloads, dropping unsaved changes
    create!(
      merchant: merchant, payment: payment, event_type: event_type,
      sequence: where(payment_id: payment.id).maximum(:sequence).to_i + 1,
      payload: PaymentSerializer.call(payment).merge(extra),
      state: deliverable ? "pending" : "delivered",
      delivered_at: deliverable ? nil : Time.current,
      next_attempt_at: Time.current,
      traceparent: Tracing.current_traceparent
    )
  end

  sig { returns(T::Boolean) }
  def delivered? = state == "delivered"

  sig { returns(T::Boolean) }
  def dead? = state == "dead"

  # Operator replay from the dead-letter state (POST /v1/events/:id/redeliver).
  # A fresh delivery with its own MAX_ATTEMPTS retries (Stripe). `attempts`
  # keeps counting, so attempt numbers stay unique per event.
  sig { returns(T::Boolean) }
  def redeliver!
    raise ArgumentError, "only dead events can be redelivered (state: #{state})" unless dead?

    update!(state: "pending", next_attempt_at: Time.current, last_error: nil, attempt_budget: attempts + MAX_ATTEMPTS)
  end

  # Wait before the next try, after failed attempt `attempt_number` (counted
  # across redeliveries). Each redelivery restarts the schedule at 1m.
  sig { params(attempt_number: Integer).returns(ActiveSupport::Duration) }
  def backoff_after(attempt_number)
    in_budget = attempt_number - (attempt_budget - MAX_ATTEMPTS)
    T.must(BACKOFF_SCHEDULE[(in_budget - 1).clamp(0, BACKOFF_SCHEDULE.size - 1)])
  end

  # The envelope the merchant receives. `id` lets them dedupe on their side;
  # `sequence` lets them drop an update older than one they already applied.
  sig { returns(T::Hash[String, T.untyped]) }
  def envelope
    { "id" => id, "type" => event_type, "livemode" => T.must(merchant).livemode,
      "created_at" => created_at.utc.iso8601(3), "sequence" => sequence, "attempt" => attempts + 1,
      "data" => payload }
  end
end
