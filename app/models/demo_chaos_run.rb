# typed: true
# frozen_string_literal: true

# One run of the demo's chaos button. It moves out of the rake file
# (app/lib/chaos_run.rb) so a Sidekiq job can drive a small run and store its
# result. A partial unique index allows only one active run system-wide
# (design §4 abuse limits).
class DemoChaosRun < ApplicationRecord
  STATES = %w[queued running passed failed errored].freeze

  validates :state, inclusion: { in: STATES }

  scope :active, -> { where(state: %w[queued running]) }
end
