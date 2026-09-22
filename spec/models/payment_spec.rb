require "rails_helper"

RSpec.describe Payment do
  let(:payment) { create(:payment) }
  # PSP timestamps must be AFTER the initial pending transition (sort_key =
  # created_at), otherwise transition! correctly treats them as stale.
  let(:t0) { payment.created_at + 1.second }

  describe "creation" do
    it "records an initial pending transition so history is complete from the start" do
      expect(payment.state).to eq("pending")
      expect(payment.transitions.count).to eq(1)
      expect(payment.transitions.first).to have_attributes(from_state: nil, to_state: "pending", most_recent: true)
    end

    it "rejects a zero amount at the model layer, before the DB CHECK" do
      expect(build(:payment, amount_minor: 0)).not_to be_valid
    end
  end

  describe "#state=" do
    it "cannot be assigned directly on a persisted payment" do
      expect { payment.update!(state: "authorized") }.to raise_error(ArgumentError, /transition!/)
    end
  end

  describe "#transition!" do
    it "applies a legal edge, flips most_recent, bumps lock_version" do
      before = payment.lock_version
      row = payment.transition!(:authorized, sort_key: t0, source: "worker")

      expect(payment.reload.state).to eq("authorized")
      expect(payment.lock_version).to eq(before + 1)
      expect(row).to have_attributes(from_state: "pending", to_state: "authorized", most_recent: true)
      expect(payment.transitions.where(most_recent: true).count).to eq(1)
    end

    it "rejects an illegal edge and leaves no trace" do
      expect { payment.transition!(:refunded, sort_key: t0, source: "webhook") }
        .to raise_error(PaymentStateMachine::IllegalTransition)
      expect(payment.reload.state).to eq("pending")
      expect(payment.transitions.count).to eq(1)
    end

    context "when webhooks arrive out of order (Q5)" do
      it "applies the newer event, records the older one as stale, and never walks backwards" do
        # captured (PSP 10:00:05) arrives first, then authorized (PSP 10:00:02)
        payment.transition!(:authorized, sort_key: t0, source: "worker") # get to a state where captured is legal
        payment.transition!(:captured, sort_key: t0 + 5, source: "webhook")
        stale = payment.transition!(:authorized, sort_key: t0 + 2, source: "webhook")

        expect(payment.reload.state).to eq("captured")
        expect(stale).to have_attributes(most_recent: false, to_state: "authorized")
        expect(stale).to be_stale
        expect(stale.metadata["superseded_by"]).to be_present
        expect(payment.transitions.where(most_recent: true).pick(:to_state)).to eq("captured")
      end

      it "does not even check legality for a stale event — stale wins over illegal" do
        payment.transition!(:authorized, sort_key: t0, source: "worker")
        payment.transition!(:captured, sort_key: t0 + 5, source: "webhook")
        # captured -> pending is illegal, but it's also stale; we record, not raise
        expect { payment.transition!(:pending, sort_key: t0 - 10, source: "webhook") }.not_to raise_error
        expect(payment.reload.state).to eq("captured")
      end
    end

    it "still applies a very late webhook if it is the newest thing we've seen, and measures the lag" do
      # Payment authorized 7 hours ago; the PSP captured it a minute later but
      # only tells us now. Newest sort_key we've seen => apply. Lag ≈ 6h59m.
      old = travel_to(7.hours.ago) { create(:payment) }
      old.transition!(:authorized, sort_key: old.created_at + 1.second, source: "worker")
      late = old.transition!(:captured, sort_key: old.created_at + 1.minute, source: "webhook")

      expect(old.reload.state).to eq("captured")
      expect(late.lag_ms).to be_within(5_000).of(((7.hours - 1.minute) * 1000).to_i)
    end

    it "raises StaleObjectError for a concurrent writer holding an old lock_version" do
      other = Payment.find(payment.id)
      payment.transition!(:authorized, sort_key: t0, source: "worker")

      # `other` still has lock_version 0; a plain save should be refused.
      other.metadata = { "note" => "x" }
      expect { other.save! }.to raise_error(ActiveRecord::StaleObjectError)
    end
  end

  describe ".stuck" do
    it "finds pending/unknown payments older than the threshold" do
      old = create(:payment)
      old.update_column(:updated_at, 20.minutes.ago)
      fresh = create(:payment)
      done = create(:payment)
      done.transition!(:authorized, sort_key: done.created_at + 1.second, source: "worker")
      done.update_column(:updated_at, 20.minutes.ago)

      expect(Payment.stuck(older_than: 15.minutes.ago)).to contain_exactly(old)
      expect(Payment.stuck(older_than: 15.minutes.ago)).not_to include(fresh, done)
    end
  end

  describe "#display_amount" do
    it "uses the currency exponent" do
      expect(create(:payment).display_amount).to eq("25.00")
      expect(create(:payment, :vnd).display_amount).to eq("500000")
    end
  end
end
