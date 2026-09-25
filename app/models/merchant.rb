# typed: true

class Merchant < ApplicationRecord
  has_many :payments, dependent: :restrict_with_exception
  has_many :ledger_accounts, dependent: :restrict_with_exception
  has_many :idempotency_keys, dependent: :restrict_with_exception
  has_many :outbound_events, dependent: :restrict_with_exception
  has_many :api_keys, dependent: :restrict_with_exception

  validates :name, presence: true
  validates :api_key_digest, presence: true, uniqueness: true
  validates :webhook_secret, presence: true
  validates :default_currency, inclusion: { in: Currency::SUPPORTED }

  # Returns [merchant, raw_key]. The raw key is shown to the merchant once
  # and never stored — only its digest is. api_key_digest is still written
  # until the column is dropped (design §2, two-step migration).
  def self.create_with_api_key!(attrs)
    transaction do
      merchant = new(attrs.merge(api_key_digest: digest(SecureRandom.hex(32)), webhook_secret: SecureRandom.hex(32)))
      merchant.save!
      key, raw = ApiKey.issue!(merchant:, livemode: true, name: "Default key")
      merchant.update!(api_key_digest: key.digest)
      [merchant, raw]
    end
  end

  # Constant-time lookup, now through api_keys so revoked and expired keys stop
  # working and many keys can be active at once.
  def self.authenticate(raw_key)
    ApiKey.authenticate(raw_key)&.merchant
  end

  def self.digest(raw) = Digest::SHA256.hexdigest(raw)

  ROTATION_GRACE = 24.hours

  # Every secret an outbound webhook is signed with right now: the current
  # one, plus the previous one while its grace period lasts (DECISIONS #15).
  def webhook_signing_secrets
    previous = previous_webhook_secret if previous_webhook_secret_expires_at&.future?
    [webhook_secret, previous].compact
  end

  # Returns the new secret — shown once, like the API key. The old one keeps
  # signing for `grace`, so the merchant can deploy the new one at leisure.
  def rotate_webhook_secret!(grace: ROTATION_GRACE)
    fresh = SecureRandom.hex(32)
    update!(previous_webhook_secret: webhook_secret, previous_webhook_secret_expires_at: grace.from_now,
            webhook_secret: fresh)
    fresh
  end
end
