# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditEvent do
  let(:merchant) { create(:merchant) }

  it "records an event with its context" do
    event = described_class.record!(action: "authorization.denied", result: "denied", merchant_id: merchant.id,
                                    actor_label: "sam@example.com", ip: "10.0.0.1",
                                    metadata: { "permission" => "payments.refund" })
    expect(event.reload.metadata).to eq("permission" => "payments.refund")
  end

  it "rejects an unknown result" do
    expect { described_class.record!(action: "x", result: "maybe") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "cannot be updated, even bypassing Rails" do
    event = described_class.record!(action: "session.created", result: "success")
    expect { described_class.where(id: event.id).update_all(action: "tampered") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "cannot delete rows younger than 12 months" do
    event = described_class.record!(action: "session.created", result: "success")
    expect { described_class.where(id: event.id).delete_all }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "allows the retention purge to delete rows older than 12 months" do
    # The database stamps created_at itself, so an old row can only be made by
    # a superuser with triggers off: exactly what the purge must cope with.
    event = described_class.record!(action: "session.created", result: "success")
    without_triggers { described_class.where(id: event.id).update_all(created_at: 13.months.ago) }
    expect { described_class.where(id: event.id).delete_all }.to change(described_class, :count).by(-1)
  end

  it "stamps created_at in the database, so a row cannot be backdated and then purged" do
    event = travel_to(13.months.ago) { described_class.record!(action: "session.created", result: "success") }
    expect(event.reload.created_at).to be_within(1.minute).of(Time.current)
    expect { described_class.where(id: event.id).delete_all }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "cannot be truncated" do
    described_class.record!(action: "session.created", result: "success")
    expect { described_class.connection.execute("TRUNCATE audit_events") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end
end
