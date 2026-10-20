require "rails_helper"

# The read that collapses ambiguity, and the one place a re-send can happen.
# Whether it may re-send after a 404 depends on whether the PSP deduplicates
# a repeated authorize (DECISIONS #12): Nordpay does, Kiripay does not.
RSpec.describe ResolveUnknownPayment do
  def result(payment, status, **overrides)
    PspAdapter::Result.new({ status: PspAdapter::Result::Status.deserialize(status.to_s), psp_reference: payment.psp_reference,
                             psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: Time.current }.merge(overrides))
  end

  context "with a PSP that does not deduplicate authorizes (Kiripay)" do
    let(:adapter) { FakePspAdapter.new(name: "kiripay", currencies: %w[VND], idempotent_authorize: false) }
    let(:payment) { create(:payment, :vnd) }

    # A Kiripay authorize sent at `sent_at`, which then timed out.
    def sent_and_unknown(sent_at)
      travel_to(sent_at, with_usec: true) { payment.mark_sent! }
      payment.transition!(:unknown, sort_key: payment.first_sent_at, source: "worker")
      payment
    end

    it "TC-B7-1: does not re-POST after a 'not found' lookup once the authorize was sent; stays unknown" do
      sent_and_unknown(5.minutes.ago)
      adapter.script(:fetch, result(payment, :not_found))

      verdict = described_class.call(payment, adapter)

      expect(verdict).to be_nil
      expect(adapter.calls[:authorize]).to be_empty
      expect(payment.reload.state).to eq("unknown")
    end

    it "TC-B7-4: a charge that never appears within LOOKUP_GRACE ends as failed, psp_never_received" do
      sent_and_unknown((described_class::LOOKUP_GRACE + 1.minute).ago)
      adapter.script(:fetch, result(payment, :not_found))

      verdict = described_class.call(payment, adapter)
      ApplyPspResult.call(payment, T.must(verdict), source: "sweeper")

      expect(adapter.calls[:authorize]).to be_empty
      expect(payment.reload.state).to eq("failed")
      expect(payment.transitions.find_by(most_recent: true).metadata).to include("decline_code" => "psp_never_received")
      expect(OutboundEvent.where(payment: payment, event_type: "payment.failed").count).to eq(1)
    end

    it "sends the first authorize when the payment was never sent (first_sent_at nil)" do
      adapter.script(:fetch, result(payment, :not_found))
      adapter.script(:authorize, result(payment, :requires_action))

      verdict = described_class.call(payment, adapter)

      expect(verdict.status).to eq(PspAdapter::Result::Status::RequiresAction)
      expect(adapter.calls[:authorize].size).to eq(1)
      expect(payment.reload.first_sent_at).to be_present
    end

    it "does not send when another sender claimed the first send after this payment was loaded" do
      stale_copy = Payment.find(payment.id) # loaded while first_sent_at was still nil
      payment.mark_sent!                    # the job got there first
      adapter.script(:fetch, result(payment, :not_found)) # its POST has not landed yet

      expect(described_class.call(stale_copy, adapter)).to be_nil
      expect(adapter.calls[:authorize]).to be_empty
    end
  end

  context "with a PSP that deduplicates authorizes (Nordpay)" do
    let(:adapter) { FakePspAdapter.new }
    let(:payment) { create(:payment) }

    it "re-sends after 'not found' with the SAME reference, however long ago it was first sent" do
      travel_to(2.hours.ago, with_usec: true) { payment.mark_sent! }
      adapter.script(:fetch, result(payment, :not_found))
      adapter.script(:authorize, result(payment, :authorized))

      verdict = described_class.call(payment, adapter)

      expect(verdict.status).to eq(PspAdapter::Result::Status::Authorized)
      expect(adapter.calls[:authorize].map(&:psp_reference)).to eq([payment.psp_reference])
    end
  end
end
