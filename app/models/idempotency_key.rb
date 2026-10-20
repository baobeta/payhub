# typed: true
# frozen_string_literal: true

class IdempotencyKey < ApplicationRecord
  extend T::Sig

  belongs_to :merchant

  TTL = 24.hours
  # A claim with no response after this long belongs to a request that died.
  # It may be re-taken; otherwise one crash means 409 forever for that key.
  LOCK_TIMEOUT = 60.seconds

  validates :key, :request_fingerprint, :expires_at, presence: true

  scope :expired, -> { where(expires_at: ..Time.current) }

  sig { returns(T::Boolean) }
  def in_flight? = locked_at.present? && response_status.nil?

  sig { returns(T::Boolean) }
  def completed? = response_status.present?

  sig { returns(T::Boolean) }
  def expired? = expires_at <= Time.current

  sig { returns(T::Boolean) }
  def abandoned? = in_flight? && T.must(locked_at) <= LOCK_TIMEOUT.ago

  # THE referee (DECISIONS #3). Claims the key by INSERT and lets the unique
  # index arbitrate; never SELECT-then-INSERT. Returns [record, won?].
  sig { params(merchant: Merchant, key: String, fingerprint: String).returns([IdempotencyKey, T::Boolean]) }
  def self.claim!(merchant, key, fingerprint)
    now = Time.current
    record = create!(merchant: merchant, key: key, request_fingerprint: fingerprint,
                     locked_at: now, expires_at: now + TTL)
    [record, true]
  rescue ActiveRecord::RecordNotUnique
    existing = find_by!(merchant: merchant, key: key)
    [existing, false]
  end

  sig { params(status: Integer, body: T.untyped).returns(T::Boolean) }
  def complete!(status, body)
    update!(response_status: status, response_body: body)
  end

  # Release a claim whose request failed with a 5xx or raised: the merchant
  # should be able to retry, not replay our bug for 24 hours.
  sig { returns(IdempotencyKey) }
  def release! = destroy!
end
