# frozen_string_literal: true

require "rails_helper"

# Payment history is written in pen (DOMAIN.md, PCI 10.3.2): the database
# itself refuses edits and deletes, not just ActiveRecord.
RSpec.describe PaymentTransition do
  let(:payment) { create(:payment) }
  let!(:first) { payment.transitions.first }

  # Each raw statement runs in a savepoint so its failure doesn't abort the example's transaction.
  def raw(sql)
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([sql, first.id]))
    end
  end

  it "TC-I2-1: the database refuses an UPDATE of a transition" do
    expect { raw("UPDATE payment_transitions SET to_state = 'failed' WHERE id = ?") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect(first.reload.to_state).to eq("pending")
  end

  it "TC-I2-2: the database refuses DELETE and TRUNCATE of transitions" do
    expect { raw("DELETE FROM payment_transitions WHERE id = ?") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { raw("TRUNCATE payment_transitions CASCADE") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect(described_class.exists?(first.id)).to be(true)
  end

  describe "TC-I2-3: the one allowed change is the most_recent true → false flip" do
    it "lets a new transition flip the previous row" do
      payment.transition!("authorized", sort_key: Time.current, source: "worker")

      expect(payment.transitions.reload.map { |t| [t.to_state, t.most_recent] })
        .to eq([["pending", false], ["authorized", true]])
    end

    it "refuses false → true" do
      payment.transition!("authorized", sort_key: Time.current, source: "worker")

      expect { raw("UPDATE payment_transitions SET most_recent = true WHERE id = ?") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "refuses the flip when the same statement changes any other column" do
      expect { raw("UPDATE payment_transitions SET most_recent = false, source = 'operator' WHERE id = ?") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { raw(%(UPDATE payment_transitions SET most_recent = false, metadata = '{"x":1}' WHERE id = ?)) }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect(first.reload).to have_attributes(most_recent: true, source: "api", metadata: {})
    end
  end
end
