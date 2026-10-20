# typed: true
# frozen_string_literal: true

# CSV exports open in spreadsheets, which run a cell starting with = + - @ as
# a formula (OWASP "CSV injection"). Free text we did not write, such as an
# invited email or an audit label, gets a leading quote.
module CsvSafe
  extend T::Sig

  TRIGGERS = ["=", "+", "-", "@", "\t", "\r"].freeze

  sig { params(value: T.untyped).returns(T.untyped) }
  def self.cell(value)
    return value unless value.is_a?(String) && value.start_with?(*TRIGGERS)

    "'#{value}"
  end

  sig { params(values: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def self.row(values) = values.map { |v| cell(v) }
end
