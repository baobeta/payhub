class IdempotencyKey < ApplicationRecord
  belongs_to :merchant

  TTL = 24.hours

  validates :key, :request_fingerprint, :expires_at, presence: true

  def in_flight? = locked_at.present? && response_status.nil?
  def completed? = response_status.present?
  def expired? = expires_at <= Time.current

  # Claiming, replay, and 409 logic live in the middleware (Phase 4).
end
