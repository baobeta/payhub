# typed: true
# frozen_string_literal: true

# A merchant's secret key. The raw key is returned once by .issue! and never
# stored; lookups go through its SHA-256 digest, which is safe for 192-bit
# random keys (slow hashes protect low-entropy passwords, not these).
class ApiKey < ApplicationRecord
  LIVE_PREFIX = "sk_live_"
  TEST_PREFIX = "sk_test_"
  LAST_USED_RESOLUTION = 1.minute

  ROLL_OVERLAPS = { "now" => 0, "24h" => 24.hours, "7d" => 7.days }.freeze

  belongs_to :merchant
  belongs_to :created_by, class_name: "MerchantUser", optional: true

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  validates :name, presence: true
  validate :belongs_to_live_merchant

  # Returns [key, raw]. Show raw to the person exactly once.
  def self.issue!(merchant:, livemode:, name:, note: nil, created_by_id: nil)
    raw = "#{livemode ? LIVE_PREFIX : TEST_PREFIX}#{SecureRandom.hex(24)}"
    key = create!(merchant:, livemode:, name:, note:, created_by_id:,
                  prefix: livemode ? LIVE_PREFIX : TEST_PREFIX, last4: raw[-4..], digest: Merchant.digest(raw))
    [key, raw]
  end

  def self.authenticate(raw)
    return nil if raw.blank?

    candidate = Merchant.digest(raw)
    key = active.find_by(digest: candidate)
    return nil unless key && ActiveSupport::SecurityUtils.secure_compare(key.digest, candidate)

    key.touch_last_used!
    key
  end

  def touch_last_used!
    last = last_used_at
    return if last && last > LAST_USED_RESOLUTION.ago

    update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations -- hot path, no validations to run
  end

  # Returns [replacement, raw]. The old key keeps working for `overlap` so a
  # deploy can pick up the new one (Stripe 7d, Adyen 24h).
  def roll!(overlap:, by:)
    transaction do
      overlap.to_i.zero? ? update!(revoked_at: Time.current) : update!(expires_at: overlap.from_now)
      ApiKey.issue!(merchant: T.must(merchant), livemode:, name:, note:, created_by_id: by&.id)
    end
  end

  def revoke! = update!(revoked_at: Time.current)

  def status
    return "revoked" if revoked_at
    return "expired" if expires_at&.past?

    expires_at ? "expiring" : "active"
  end

  # Which data space this key opens: the live merchant or its test twin.
  def merchant_for_mode = livemode ? merchant : T.must(merchant).test_twin!

  private

  def belongs_to_live_merchant
    errors.add(:merchant, "must be the live merchant; test keys open its twin") unless merchant&.livemode
  end
end
