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

  # TC-I5-2: the same invariants with everything the first property leaves
  # out. Several payments for two merchants, in EUR (a Nordpay-like PSP) and
  # VND (a Kiripay-like one that does not deduplicate). Both PSPs decline,
  # time out before and after recording, and refuse some refunds. Captures
  # (some non-final, so a payment is captured again), refunds and cancels are
  # interleaved with the jobs they enqueue. Fixed seeds: a failure replays.
  describe "TC-I5-2 many payments, two currencies, a faulty PSP" do
    def drain!
      40.times do
        jobs = enqueued_jobs.dup
        break if jobs.empty?

        enqueued_jobs.clear
        jobs.each do |job|
          ActiveJob::Base.execute(job)
        rescue PspAdapter::TimedOut, PspAdapter::Unavailable
          enqueued_jobs << job # escaped the job: Sidekiq retries it later
        end
      end
    end

    # Faults off; let jobs and the sweeper resolve every unknown and pending.
    def settle!(psps)
      psps.each_value { |psp| psp.faults = false }
      clock = Time.current
      30.times do
        drain!
        travel_to(clock += 31.minutes)
        StuckPaymentSweeperJob.perform_now
        drain!
      end
    end

    def act(rng, payment)
      case %i[capture capture refund refund cancel].sample(random: rng)
      when :capture
        amount = rng.rand < 0.3 ? nil : rng.rand(1..(payment.amount_minor * 1.2).ceil)
        CapturePayment.call(payment, amount_minor: amount, final: rng.rand < 0.5)
      when :refund then CreateRefund.call(payment, amount_minor: rng.rand(1..payment.amount_minor))
      when :cancel then CancelPayment.call(payment)
      end
    rescue ApiError, PspAdapter::TimedOut, PspAdapter::Unavailable
      nil # refused by a guard, or the PSP failed a synchronous call
    end

    # Per merchant per currency, at any instant.
    def check!(merchants, context)
      expect(Ledger.unbalanced_transfer_ids).to be_empty, "unbalanced transfer — #{context}"
      merchants.each do |merchant|
        balances = Ledger.balances(merchant)
        reserved_balances = Ledger.reserved_balances(merchant)
        merchant.payments.group_by(&:currency).each do |currency, payments|
          rows = payments.map { |p| [p, Ledger.captured_minor(p), Ledger.refunded_minor(p), Ledger.reserved_minor(p)] }
          rows.each do |p, captured, refunded, reserved|
            where = "#{p.currency} payment #{p.id} (#{p.state}) — #{context}"
            expect(captured).to be <= p.amount_minor, "over-capture: #{captured} > #{p.amount_minor}, #{where}"
            expect(refunded + reserved).to be <= captured, "over-refund: #{refunded}+#{reserved} > #{captured}, #{where}"
          end
          owed = rows.sum { |_, captured, refunded, reserved| captured - refunded - reserved }
          expect(balances.fetch(currency, 0)).to eq(owed), "balance drift in #{currency} — #{context}"
          expect(reserved_balances.fetch(currency, 0)).to eq(rows.sum(&:last)), "reserved drift in #{currency} — #{context}"
        end
      end
    end

    (1..ENV.fetch("PROPERTY_RUNS", 25).to_i).each do |seed|
      it "TC-I5-2 holds for seed #{seed}" do
        rng = Random.new(seed)
        create(:fx_rate, base: "VND", quote: "EUR")
        psps = { "nordpay" => SimPsp.new(rng, rates: { refund_reject: 0.15 }),
                 "kiripay" => SimPsp.kiripay_like(rng, rates: { refund_reject: 0.15 }) }
        allow(PspRouter).to receive(:adapter) { |name| psps.fetch(name) }
        allow(Rails.logger).to receive(:error) # expected under faults; the invariants are the judge

        merchants = create_list(:merchant, 2)
        payments = Array.new(rng.rand(3..6)) do
          currency = %w[EUR VND].sample(random: rng)
          CreatePayment.call(merchants.sample(random: rng),
                             CreatePayment::Params.new(amount_minor: rng.rand(500..20_000), currency:,
                                                       payment_method_token: "tok_visa"))
        end
        drain!

        log = []
        rng.rand(8..20).times do |n|
          payment = payments.sample(random: rng).reload
          log << "#{n}:#{payment.currency}/#{payment.state}"
          act(rng, payment)
          drain! if rng.rand < 0.7 # sometimes the next action races the jobs of this one
          check!(merchants, "seed=#{seed} steps=#{log.join(' ')}")
        end
        settle!(psps)

        context = "seed=#{seed} settled, steps=#{log.join(' ')}"
        check!(merchants, context)
        payments.each do |p|
          psp = psps.fetch(p.psp_name)
          expect(Ledger.reserved_minor(p)).to eq(0), "reservation outlived its refund — #{context}"
          expect(Ledger.captured_minor(p)).to eq(psp.captured_for(p.psp_reference)), "captured != PSP — #{context}"
          expect(Ledger.refunded_minor(p)).to eq(psp.refunded_for(p.psp_reference)), "refunded != PSP — #{context}"
        end
        expect(psps.values.flat_map { |psp| psp.duplicate_charges.keys }).to be_empty, "double charge — #{context}"
      end
    end
  end
end
