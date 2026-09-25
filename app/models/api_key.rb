# typed: true
# frozen_string_literal: true

# A merchant's secret key. The raw key is returned once by .issue! and never
# stored; lookups go through its SHA-256 digest, which is safe for 192-bit
# random keys (slow hashes protect low-entropy passwords, not these).
class ApiKey < ApplicationRecord
  LIVE_PREFIX = "sk_live_"
  TEST_PREFIX = "sk_test_"
  LAST_USED_RESOLUTION = 1.minute

  belongs_to :merchant

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

  # Which data space this key opens: the live merchant or its test twin.
  def merchant_for_mode = livemode ? merchant : T.must(merchant).test_twin!

  private

  def belongs_to_live_merchant
    errors.add(:merchant, "must be the live merchant; test keys open its twin") unless merchant&.livemode
  end
end
