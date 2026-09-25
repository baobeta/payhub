# typed: true
# frozen_string_literal: true

# Strips anything sensitive from a PSP request or response body before it is
# stored in psp_calls. Runs on every call, so it must never raise.
module PspCallRedactor
  MASK = "[REDACTED]"

  # A key is sensitive when one of its words is one of these. Keys are split on
  # _, -, spaces and camelCase humps, and matched as whole words, so
  # "reference" and "decline_code" survive while "payment_method_token" and
  # "clientSecret" do not.
  SENSITIVE_WORDS = %w[token secret signature authorization password cvc cvv pan number apikey
                       credential credentials pin iban].freeze
  # "key" alone is too common (idempotency_key, sort_key); after these it is a secret.
  KEY_QUALIFIERS = %w[private secret access api].freeze

  # name=value pairs in a URL query string, e.g. a redirect URL carrying a token.
  QUERY_PARAM = /([?&])([^=&#\s]+)=([^&#\s]*)/

  # 13-19 digits, optionally grouped by spaces or dashes: the shape of a PAN.
  CARD_LIKE = /(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/

  # @param body [Hash, Array, String, Integer, nil] a parsed JSON value
  # @return the same shape, with sensitive values replaced by MASK
  def self.redact(body)
    walk(body)
  rescue StandardError
    # Unknown shape: storing nothing beats storing a secret in an
    # append-only table that cannot be scrubbed afterwards.
    body.nil? ? nil : MASK
  end

  def self.walk(value)
    case value
    when Hash then value.to_h { |k, v| [k, sensitive_key?(k) ? MASK : walk(v)] }
    when Array then value.map { |v| walk(v) }
    when String then redact_string(value)
    when Integer then luhn?(value.to_s) && value.to_s.length.between?(13, 19) ? MASK : value
    else value
    end
  end
  private_class_method :walk

  def self.redact_string(value)
    masked = value.gsub(QUERY_PARAM) do |pair|
      sep, name = Regexp.last_match(1), Regexp.last_match(2)
      sensitive_key?(name) ? "#{sep}#{name}=#{MASK}" : pair
    end
    masked.gsub(CARD_LIKE) { |m| luhn?(m) ? MASK : m }
  end
  private_class_method :redact_string

  def self.sensitive_key?(key)
    words = key.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.split(/[^a-z0-9]+/)
    words.any? { |w| SENSITIVE_WORDS.include?(w) } ||
      words.each_cons(2).any? { |before, word| word == "key" && KEY_QUALIFIERS.include?(before) }
  end
  private_class_method :sensitive_key?

  # Luhn separates real card numbers from long ids and amounts, which keeps
  # those visible to operators.
  def self.luhn?(candidate)
    digits = candidate.delete("^0-9").reverse.chars.map(&:to_i)
    return false unless digits.length.between?(13, 19)

    sum = digits.each_with_index.sum { |d, i| i.odd? ? (d * 2).divmod(10).sum : d }
    (sum % 10).zero?
  end
  private_class_method :luhn?
end
