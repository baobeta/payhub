require "rails_helper"

# Property-style test. For ANY sequence of capture and refund calls — random
# amounts, random order, some deliberately out of range — two things must
# hold when the dust settles:
#
#   1. every ledger transfer nets to zero (the books balance), and
#   2. refunded never exceeds captured, and captured never exceeds authorized.
#
# The PSP is a FakePspAdapter that ALWAYS says yes, so the only thing that
# can prevent an over-refund or over-capture is our own guard. A seed is
# printed on failure so the sequence can be replayed.
RSpec.describe "Ledger invariants", type: :property do
  runs = ENV.fetch("PROPERTY_RUNS", 25).to_i

  def build_adapter(payment)
    FakePspAdapter.new.tap do |a|
      # Answer every capture with the PSP's running total (what a real PSP does),
      # and every refund with success. Lazy procs read live state.
      running_total = 0
      # CapturePaymentJob reads before it writes (DECISIONS #20): report the total.
      a.define_singleton_method(:fetch) do |_ref|
        PspAdapter::Result.new(status: PspAdapter::Result::Status::Authorized, psp_reference: payment.psp_reference,
                               psp_charge_id: "ch", decline_code: nil, psp_timestamp: Time.current,
                               raw: { "captured_minor" => running_total })
      end
      a.define_singleton_method(:capture) do |_p, amount|
        running_total += amount
        PspAdapter::Result.new(status: PspAdapter::Result::Status::Captured, psp_reference: payment.psp_reference,
                               psp_charge_id: "ch", decline_code: nil, psp_timestamp: Time.current,
                               raw: { "captured_minor" => running_total })
      end
      a.define_singleton_method(:refund) do |refund|
        PspAdapter::RefundResult.new(status: PspAdapter::RefundResult::Status::Succeeded, psp_reference: refund.psp_reference,
                                     psp_refund_id: "re", failure_code: nil, psp_timestamp: Time.current)
      end
    end
  end

  runs.times do |i|
    it "holds for random sequence ##{i}" do
      seed = ENV["PROPERTY_SEED"]&.to_i || Random.new_seed
      rng = Random.new(seed)

      authorized = rng.rand(100..10_000)
      payment = create(:payment, amount_minor: authorized)
      payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")
      allow(PspRouter).to receive(:adapter).and_return(build_adapter(payment))

      steps = rng.rand(3..12)
      log = []
      steps.times do
        # Amounts deliberately sometimes exceed what is legal: the guard must reject those.
        amount = rng.rand(1..(authorized * 1.5).to_i)
        op = rng.rand < 0.5 ? :capture : :refund
        log << [op, amount]
        begin
          case op
          when :capture
            CapturePayment.call(payment.reload, amount_minor: amount)
            perform_enqueued_jobs
          when :refund
            CreateRefund.call(payment.reload, amount_minor: amount)
            perform_enqueued_jobs
          end
        rescue ApiError
          # rejected by a guard: expected for out-of-range or wrong-state attempts
        end
      end

      captured = Ledger.captured_minor(payment)
      refunded = Ledger.refunded_minor(payment)
      msg = "seed=#{seed} authorized=#{authorized} steps=#{log.inspect} captured=#{captured} refunded=#{refunded}"

      expect(Ledger.unbalanced_transfer_ids).to be_empty, "unbalanced transfer — #{msg}"
      expect(captured).to be <= authorized, "over-capture — #{msg}"
      expect(refunded).to be <= captured, "over-refund — #{msg}"
      expect(Ledger.balances(payment.merchant)["EUR"].to_i).to eq(captured - refunded), "balance drift — #{msg}"
    end
  end
end
