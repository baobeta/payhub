require "rails_helper"

RSpec.describe RefundPaymentJob do
  let(:payment) { create(:payment) }
  let(:adapter) { FakePspAdapter.new }
  let(:t_psp) { payment.created_at + 3.seconds }

  before do
    allow(PspRouter).to receive(:adapter).with("nordpay").and_return(adapter)
    payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")
    Ledger.record_capture!(payment, 2500)
    payment.transition!(:captured, sort_key: payment.created_at + 2.seconds, source: "worker")
  end

  def outcome(status, ref, code: nil)
    PspAdapter::RefundResult.new(
      status: PspAdapter::RefundResult::Status.deserialize(status.to_s), psp_reference: ref,
      psp_refund_id: "re_1", failure_code: code, psp_timestamp: t_psp
    )
  end

  describe "TC-F1-1: one full refund with default amount → refunded" do
    it "TC-F1-1: a refund with no explicit amount on a €25 captured payment ends the payment refunded" do
      # Default amount = full captured amount (€25.00 = 2500 minor)
      refund = create(:refund, payment: payment, amount_minor: 2500)
      adapter.script(:refund, outcome(:succeeded, refund.psp_reference))

      described_class.perform_now(refund.id)

      expect(refund.reload.state).to eq("succeeded")
      expect(payment.reload.state).to eq("refunded")
      expect(Ledger.refunded_minor(payment)).to eq(2500)
    end
  end

  describe "TC-F10-1: refund outbound events carry refund id, amount_minor, and failure_code" do
    it "TC-F10-1a: refund.succeeded event has refund.id and amount_minor" do
      refund = create(:refund, payment: payment, amount_minor: 1000)
      adapter.script(:refund, outcome(:succeeded, refund.psp_reference))

      described_class.perform_now(refund.id)

      event = OutboundEvent.find_by!(payment: payment, event_type: "refund.succeeded")
      expect(event.payload["refund"]["id"]).to eq(refund.id)
      expect(event.payload["refund"]["amount_minor"]).to eq(1000)
    end

    it "TC-F10-1b: refund.failed event has refund.id, amount_minor, and failure_code" do
      refund = create(:refund, payment: payment, amount_minor: 500)
      adapter.script(:refund, outcome(:failed, refund.psp_reference, code: "insufficient_funds"))

      described_class.perform_now(refund.id)

      event = OutboundEvent.find_by!(payment: payment, event_type: "refund.failed")
      expect(event.payload["refund"]["id"]).to eq(refund.id)
      expect(event.payload["refund"]["amount_minor"]).to eq(500)
      expect(event.payload["failure_code"]).to be_present
    end
  end

  it "books a succeeded partial refund and moves captured → part_refunded" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, outcome(:succeeded, refund.psp_reference))

    described_class.perform_now(refund.id)

    expect(refund.reload.state).to eq("succeeded")
    expect(Ledger.refunded_minor(payment)).to eq(500)
    expect(payment.reload.state).to eq("part_refunded")
    expect(Ledger.balances(payment.merchant)).to eq("EUR" => 2000)
  end

  it "moves to refunded when the refunded total reaches the captured total" do
    first = create(:refund, payment: payment, amount_minor: 1500)
    second = create(:refund, payment: payment, amount_minor: 1000)
    adapter.script(:refund, outcome(:succeeded, first.psp_reference), outcome(:succeeded, second.psp_reference))

    described_class.perform_now(first.id)
    described_class.perform_now(second.id)

    expect(payment.reload.state).to eq("refunded")
    expect(Ledger.refunded_minor(payment)).to eq(2500)
  end

  it "marks a failed refund failed and books nothing" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, outcome(:failed, refund.psp_reference, code: "exceeds_captured"))

    described_class.perform_now(refund.id)

    expect(refund.reload.state).to eq("failed")
    expect(Ledger.refunded_minor(payment)).to eq(0)
    expect(payment.reload.state).to eq("captured")
    # the reservation is voided: the merchant's money is available again
    expect(Ledger.reserved_minor(payment)).to eq(0)
    expect(Ledger.balances(payment.merchant)).to eq("EUR" => 2500)
  end

  describe "a refund the PSP rejects (bug 2)" do
    it "TC-BUG2-1: fails the refund, voids its reservation and tells the merchant" do
      refund = create(:refund, payment: payment, amount_minor: 1000)
      adapter.script(:refund, PspAdapter::Rejected.new(422, "nordpay 422: refund exceeds captured"))
      adapter.script(:fetch_refund, outcome(:not_found, refund.psp_reference))

      described_class.perform_now(refund.id)

      expect(refund.reload.state).to eq("failed") # the code travels on the refund.failed event
      expect(Ledger.reserved_minor(payment)).to eq(0)
      expect(Ledger.balances(payment.merchant)).to eq("EUR" => 2500)
      event = OutboundEvent.find_by!(payment: payment, event_type: "refund.failed")
      expect(event.payload["failure_code"]).to eq("psp_rejected_422")
      expect(payment.reload.state).to eq("captured")
    end

    it "TC-BUG2-2: a Kiripay refund whose charge cannot be found fails cleanly, and is not re-driven" do
      refund = create(:refund, payment: payment, amount_minor: 2500)
      adapter.script(:refund, PspAdapter::Rejected.new(404, "kiripay charge not found"))
      adapter.script(:fetch_refund, outcome(:not_found, refund.psp_reference))

      described_class.perform_now(refund.id)

      expect(refund.reload.state).to eq("failed")
      expect(OutboundEvent.find_by!(event_type: "refund.failed").payload["failure_code"]).to eq("psp_rejected_404")
      expect(Ledger.reserved_minor(payment)).to eq(0)
      expect(Refund.where(state: "pending")).to be_empty # nothing left for the sweeper
      described_class.perform_now(refund.id) # a stray re-run: no scripted answer, so a PSP call would raise
      expect(adapter.calls[:refund].size).to eq(1)
    end

    it "TC-BUG2-3: a refusal of a refund that already landed (Kiripay 409 already_refunded on a re-run) succeeds, never fails" do
      # The first POST landed but its answer was lost (Unavailable → retry, or a
      # sweeper re-drive). Kiripay has no idempotency key, so the re-run's POST
      # is refused. Failing it would void the reservation: the customer has the
      # money AND the merchant gets it back — paid twice.
      refund = create(:refund, payment: payment, amount_minor: 2500)
      adapter.script(:refund, PspAdapter::Rejected.new(409, "kiripay 409: charge already refunded"))
      adapter.script(:fetch_refund, outcome(:succeeded, refund.psp_reference))

      described_class.perform_now(refund.id)

      expect(refund.reload.state).to eq("succeeded")
      expect(Ledger.refunded_minor(payment)).to eq(2500)
      expect(Ledger.reserved_minor(payment)).to eq(0)
      expect(Ledger.balances(payment.merchant)).to eq("EUR" => 0)
      expect(OutboundEvent.where(payment: payment, event_type: "refund.failed")).to be_empty
    end

    it "TC-BUG2-4: a 2xx the adapter could not read (Rejected 200) leaves the refund pending, reservation held" do
      refund = create(:refund, payment: payment, amount_minor: 1000)
      adapter.script(:refund, PspAdapter::Rejected.new(200, "nordpay refund status unreadable"))

      described_class.perform_now(refund.id)

      expect(refund.reload.state).to eq("pending")
      expect(Ledger.reserved_minor(payment)).to eq(1000)
      expect(OutboundEvent.where(payment: payment, event_type: "refund.failed")).to be_empty
    end
  end

  describe "refunds between partial captures (DECISIONS #20)" do
    it "TC-E3-9: refunding everything captured while capturing is open is not terminal, until capturing closes" do
      open = create(:payment, merchant: payment.merchant) # €25 authorized, €10 captured non-final
      open.transition!(:authorized, sort_key: open.created_at + 1.second, source: "worker")
      Ledger.record_capture!(open, 1000)
      open.update_column(:captured_minor, 1000)
      open.transition!(:captured, sort_key: open.created_at + 2.seconds, source: "worker")
      refund = create(:refund, payment: open, amount_minor: 1000)
      adapter.script(:refund, outcome(:succeeded, refund.psp_reference))

      described_class.perform_now(refund.id)

      expect(open.reload.state).to eq("part_refunded")
      expect(open.capturable_minor(Ledger.captured_minor(open))).to eq(1500)

      CapturePayment.call(open, amount_minor: 0, final: true)

      expect(open.reload.state).to eq("refunded")
      expect(open.captures_closed_at).to be_present
    end
  end

  describe "two-phase settlement (DECISIONS #16)" do
    it "holds the amount as reserved until the PSP answers, then posts it" do
      refund = create(:refund, payment: payment, amount_minor: 500)
      expect(Ledger.reserved_minor(payment)).to eq(500)
      expect(Ledger.balances(payment.merchant)).to eq("EUR" => 2000)
      expect(Ledger.reserved_balances(payment.merchant)).to eq("EUR" => 500)

      adapter.script(:refund, outcome(:succeeded, refund.psp_reference))
      described_class.perform_now(refund.id)

      expect(reserved: Ledger.reserved_minor(payment), refunded: Ledger.refunded_minor(payment)).to eq(reserved: 0, refunded: 500)
      expect(Ledger.balances(payment.merchant)).to eq("EUR" => 2000)
      expect(Ledger.unbalanced_transfer_ids).to be_empty
    end

    it "is refused by the database if a refund is settled twice, or posted after a void" do
      refund = create(:refund, payment: payment, amount_minor: 500)
      Ledger.post_refund!(refund)

      expect { Ledger.post_refund!(refund) }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { Ledger.void_refund!(refund) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "refuses to settle a refund that never reserved" do
      refund = create(:refund, payment: payment, amount_minor: 500, state: "succeeded") # no reservation
      expect { Ledger.post_refund!(refund) }.to raise_error(Ledger::NoReservation)
    end
  end

  it "is idempotent: a second run finds the refund resolved and never calls the PSP (perform-twice test)" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, outcome(:succeeded, refund.psp_reference)) # only one answer; a 2nd call would raise

    described_class.perform_now(refund.id)
    ledger_before = LedgerEntry.pluck(:id).sort
    described_class.perform_now(refund.id)

    expect(LedgerEntry.pluck(:id).sort).to eq(ledger_before)
    expect(adapter.calls[:refund].size).to eq(1)
  end

  it "on timeout, resolves by fetching OUR refund reference — never re-sends the refund" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, PspAdapter::TimedOut)
    adapter.script(:fetch_refund, outcome(:succeeded, refund.psp_reference))

    described_class.perform_now(refund.id)

    expect(adapter.calls[:refund].size).to eq(1)
    expect(adapter.calls[:fetch_refund]).to eq([refund.psp_reference])
    expect(refund.reload.state).to eq("succeeded")
  end

  it "on timeout where the PSP never saw it, leaves the refund pending for the sweeper" do
    refund = create(:refund, payment: payment, amount_minor: 500)
    adapter.script(:refund, PspAdapter::TimedOut)
    adapter.script(:fetch_refund, outcome(:not_found, refund.psp_reference))

    described_class.perform_now(refund.id)

    expect(refund.reload.state).to eq("pending")
    expect(Ledger.refunded_minor(payment)).to eq(0)
  end
end
