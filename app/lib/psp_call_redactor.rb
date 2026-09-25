# typed: true
# frozen_string_literal: true

# Strips anything sensitive from a PSP request or response body before it is
# stored in psp_calls. Runs on every call, so it must never raise.
module PspCallRedactor
  MASK = "[REDACTED]"

  # A key is sensitive when one of its words (split on _ and -) is one of these.
  # Whole words, so "reference" and "decline_code" survive while
  # "payment_method_token" and "webhook_secret" do not.
  SENSITIVE_WORDS = %w[token secret signature authorization password cvc cvv pan number apikey].freeze

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
    when String then value.gsub(CARD_LIKE) { |m| luhn?(m) ? MASK : m }
    when Integer then luhn?(value.to_s) && value.to_s.length.between?(13, 19) ? MASK : value
    else value
    end
  end
  private_class_method :walk

  def self.sensitive_key?(key)
    words = key.to_s.downcase.split(/[_\-\s]+/)
    words.any? { |w| SENSITIVE_WORDS.include?(w) } || words.each_cons(2).any? { |pair| pair.join == "apikey" }
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
