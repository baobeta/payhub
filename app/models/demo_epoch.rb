# typed: true
# frozen_string_literal: true

# A demo "reset" starts a new epoch. Payments and ledger entries are
# append-only (DECISIONS #5), so instead of deleting anything the demo just
# hides every row created before the latest epoch.
class DemoEpoch < ApplicationRecord
  # ActiveSupport pluralizes "epoch" to "epoches"; the table, per the phase 3
  # plan, is demo_epochs.
  self.table_name = "demo_epochs"

  validates :started_at, presence: true

  def self.current = order(:started_at).last
  def self.started_at = current&.started_at || Time.zone.at(0)
end
