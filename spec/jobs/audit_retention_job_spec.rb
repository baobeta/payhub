# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditRetentionJob do
  def backdate(model, id, to)
    without_triggers { model.where(id:).update_all(created_at: to) } # rubocop:disable Rails/SkipsModelValidations
  end

  it "deletes audit events and PSP calls older than 12 months and keeps the rest" do
    old_event = AuditEvent.record!(action: "session.created", result: "success")
    new_event = AuditEvent.record!(action: "session.created", result: "success")
    old_call = PspCall.create!(psp_name: "nordpay", operation: "GET /x", outcome: "ok", duration_ms: 1, sent_at: Time.current)
    backdate(AuditEvent, old_event.id, 13.months.ago)
    backdate(PspCall, old_call.id, 13.months.ago)

    described_class.perform_now

    expect(AuditEvent.where(id: [old_event.id, new_event.id]).pluck(:id)).to eq([new_event.id])
    expect(PspCall.exists?(old_call.id)).to be(false)
  end
end
