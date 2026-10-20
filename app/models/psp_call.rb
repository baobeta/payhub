# typed: true
# frozen_string_literal: true

class PspCall < ApplicationRecord
  extend T::Sig

  OUTCOMES = %w[ok http_error timeout unreachable].freeze
  validates :outcome, inclusion: { in: OUTCOMES }

  sig { returns(T::Boolean) }
  def readonly? = persisted?
end
