# frozen_string_literal: true

require "rails_helper"

RSpec.describe PspCall do
  def record!
    described_class.create!(psp_name: "nordpay", operation: "GET /x", outcome: "ok", duration_ms: 1,
                            sent_at: Time.current)
  end

  it "cannot be updated" do
    call = record!
    expect { described_class.where(id: call.id).update_all(outcome: "timeout") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "cannot be truncated" do
    record!
    expect { described_class.connection.execute("TRUNCATE psp_calls") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "stamps created_at in the database" do
    call = travel_to(13.months.ago) { record! }
    expect(call.reload.created_at).to be_within(1.minute).of(Time.current)
  end
end
