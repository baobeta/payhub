# typed: true
# frozen_string_literal: true

# Ten single-use codes, shown once. Stored as SHA-256 digests: each has 50
# random bits, so a slow hash adds nothing but latency.
class RecoveryCode < ApplicationRecord
  COUNT = 10

  belongs_to :principal, polymorphic: true

  def self.normalize(raw) = raw.to_s.downcase.delete("^a-z0-9")

  # Returns the raw codes, formatted xxxxx-xxxxx.
  def self.regenerate!(principal)
    codes = Array.new(COUNT) { SecureRandom.alphanumeric(10).downcase.insert(5, "-") }
    transaction do
      where(principal:).delete_all
      codes.each { |c| create!(principal:, code_digest: Digest::SHA256.hexdigest(normalize(c))) }
    end
    codes
  end

  def self.consume!(principal, raw)
    digest = Digest::SHA256.hexdigest(normalize(raw))
    where(principal:, used_at: nil, code_digest: digest).update_all(used_at: Time.current) == 1 # rubocop:disable Rails/SkipsModelValidations
  end
end
