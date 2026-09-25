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
    event = travel_to(13.months.ago) { described_class.record!(action: "session.created", result: "success") }
    expect { described_class.where(id: event.id).delete_all }.to change(described_class, :count).by(-1)
  end
end
