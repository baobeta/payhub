# typed: true
# frozen_string_literal: true

class PspCall < ApplicationRecord
  OUTCOMES = %w[ok http_error timeout unreachable].freeze
  validates :outcome, inclusion: { in: OUTCOMES }
  def readonly? = persisted?
end
