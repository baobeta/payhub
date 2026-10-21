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

  it "TC-K1-2 refuses to delete a row younger than 12 months" do
    call = record!
    expect { described_class.transaction(requires_new: true) { described_class.where(id: call.id).delete_all } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only \(attempted DELETE\)/)
    expect(described_class.exists?(call.id)).to be(true)
  end

  it "TC-K1-2 refuses a row just inside the 12 months" do
    call = record!
    without_triggers { described_class.where(id: call.id).update_all(created_at: 11.months.ago) } # rubocop:disable Rails/SkipsModelValidations
    expect { described_class.where(id: call.id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "TC-K1-2 lets the retention purge delete a row older than 12 months" do
    call = record!
    # created_at is stamped by the database; only a trigger-free session can backdate it.
    without_triggers { described_class.where(id: call.id).update_all(created_at: 13.months.ago) } # rubocop:disable Rails/SkipsModelValidations
    expect { described_class.where(id: call.id).delete_all }.to change(described_class, :count).by(-1)
  end
end
