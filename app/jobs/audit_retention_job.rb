# typed: true
# frozen_string_literal: true

# PCI DSS 10.5.1: keep 12 months. The append-only trigger lets exactly this
# through (rows older than the window) and nothing else.
class AuditRetentionJob < ApplicationJob
  queue_as :sweepers

  BATCH = 1_000

  def perform
    cutoff = 12.months.ago - 1.day # a day of slack so we never race the trigger's own clock
    [AuditEvent, PspCall].each do |model|
      loop do
        ids = model.where(created_at: ...cutoff).limit(BATCH).pluck(:id)
        break if ids.empty?

        model.where(id: ids).delete_all
      end
    end
  end
end
