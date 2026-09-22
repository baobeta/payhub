class Merchant < ApplicationRecord
  has_many :payments, dependent: :restrict_with_exception
  has_many :ledger_accounts, dependent: :restrict_with_exception
  has_many :idempotency_keys, dependent: :restrict_with_exception
  has_many :outbound_events, dependent: :restrict_with_exception

  validates :name, presence: true
  validates :api_key_digest, presence: true, uniqueness: true
  validates :webhook_secret, presence: true
  validates :default_currency, inclusion: { in: Currency::SUPPORTED }

  API_KEY_PREFIX = "sk_live_"

  # Returns [merchant, raw_key]. The raw key is shown to the merchant once
  # and never stored — only its digest is.
  def self.create_with_api_key!(attrs)
    raw = "#{API_KEY_PREFIX}#{SecureRandom.hex(24)}"
    merchant = create!(attrs.merge(
      api_key_digest: digest(raw),
      webhook_secret: SecureRandom.hex(32)
    ))
    [ merchant, raw ]
  end

  # Constant-time authentication. We look up by digest (an indexed equality
  # query is fine — the digest is not secret) and then secure_compare so the
  # final check does not leak a byte-by-byte timing signal.
  def self.authenticate(raw_key)
    return nil if raw_key.blank?

    candidate = digest(raw_key)
    merchant = find_by(api_key_digest: candidate)
    return nil unless merchant

    ActiveSupport::SecurityUtils.secure_compare(merchant.api_key_digest, candidate) ? merchant : nil
  end

  def self.digest(raw) = Digest::SHA256.hexdigest(raw)
end
