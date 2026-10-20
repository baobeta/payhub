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
  MAX_ATTEMPTS = 8
  # 1m, 2m, 4m, 8m, 16m, 32m, 64m — a little over two hours before dead-lettering.
  BACKOFF = ->(attempt) { (2**(attempt - 1)).minutes }

  validates :event_type, :payload, presence: true
  validates :state, inclusion: { in: STATES }

  scope :due, -> { where(state: "pending").where(next_attempt_at: ..Time.current).order(:next_attempt_at) }

  # Called INSIDE the caller's transaction (Payment#transition!, refund jobs).
  # A merchant with no webhook_url still gets the event — it is queryable via
  # GET /v1/events — but nothing is delivered, so it is born delivered.
  sig { params(payment: Payment, event_type: String, extra: T::Hash[String, T.untyped]).returns(OutboundEvent) }
  def self.emit!(payment, event_type, extra = {})
    merchant = T.must(payment.merchant)
    deliverable = merchant.webhook_url.present?
    create!(
      merchant: merchant, payment: payment, event_type: event_type,
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

  # The envelope the merchant receives. `id` lets them dedupe on their side.
  sig { returns(T::Hash[String, T.untyped]) }
  def envelope
    { "id" => id, "type" => event_type, "livemode" => T.must(merchant).livemode,
      "created_at" => created_at.utc.iso8601(3), "attempt" => attempts + 1, "data" => payload }
  end
end
