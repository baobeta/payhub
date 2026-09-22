require "rails_helper"

# The second real-threads test (the first is the idempotency-key race).
#
# A €25.00 capture. N threads each try to refund €20.00 at the same instant,
# with DIFFERENT idempotency keys, so nothing upstream dedupes them. The only
# thing standing between the merchant and a €40 refund on a €25 capture is
# CreateRefund's FOR UPDATE + ledger sum + pending reservation (DECISIONS #6).
RSpec.describe CreateRefund do
  it "lets exactly one of N simultaneous refunds through when together they would exceed the capture", :concurrency do
    merchant = create(:merchant)
    payment = create(:payment, merchant: merchant, amount_minor: 2500)
    payment.transition!(:authorized, sort_key: payment.created_at + 1.second, source: "worker")
    Ledger.record_capture!(payment, 2500)
    payment.transition!(:captured, sort_key: payment.created_at + 2.seconds, source: "worker")
    allow(PspRouter).to receive(:adapter).and_return(FakePspAdapter.new)

    contenders = 4 # < connection pool size, see idempotency_guard_spec
    barrier = Concurrent::CyclicBarrier.new(contenders)
    outcomes = Concurrent::Array.new

    threads = contenders.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          outcomes << described_class.call(Payment.find(payment.id), amount_minor: 2000)
        rescue ApiError => e
          outcomes << e
        end
      end
    end
    threads.each(&:join)

    accepted = outcomes.grep(Refund)
    rejected = outcomes.grep(ApiError)

    expect(accepted.size).to eq(1)
    expect(rejected.size).to eq(contenders - 1)
    expect(rejected.map(&:http_status).uniq).to eq([422])
    expect(rejected.first.details["amount_minor"].first).to include("pending 2000")

    # The invariant, checked from the rows: reserved + refunded never exceeds captured.
    reserved = Refund.where(payment: payment, state: "pending").sum(:amount_minor)
    expect(reserved + Ledger.refunded_minor(payment)).to be <= Ledger.captured_minor(payment)
  end
end
