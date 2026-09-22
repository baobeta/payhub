# typed: true

# One row per state change, append-only. `sort_key` is the PSP's own event
# timestamp; `created_at` is when we heard about it. Their difference is the
# webhook lag we log.
class PaymentTransition < ApplicationRecord
  belongs_to :payment

  SOURCES = %w[api worker webhook sweeper operator].freeze

  validates :to_state, inclusion: { in: PaymentStateMachine::STATES }
  validates :source, inclusion: { in: SOURCES }
  validates :sort_key, presence: true

  # Only Payment#transition! may create these; it holds the row lock.
  # Never updated after creation except the most_recent flip, which
  # transition! does via update_column under the same lock.
  before_update { raise ActiveRecord::ReadOnlyRecord, "payment_transitions is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "payment_transitions is append-only" }

  # A stale row was recorded for audit but never moved state. An applied row
  # did move state at the time, even if a later transition has since
  # superseded it (most_recent is now false).
  def stale? = metadata["stale"] == true
  def applied? = !stale?

  def lag_ms = ((created_at - sort_key) * 1000).round
end
