# typed: false
# frozen_string_literal: true

# Deterministic simulation (DECISIONS #19), in the spirit of TigerBeetle's VOPR
# and FoundationDB's simulator, scaled to one Rails process: ONE seed drives
# the PSP's faults, the order jobs run in, which jobs run twice (a crash after
# commit), which webhooks arrive late, twice or never, what merchants do, and
# a virtual clock. Invariants are checked after every step; once faults stop
# and everything drains, our books must equal the PSP's truth exactly.
#
# The run stops at the first violation and reports it with the seed and the
# steps that led there, so it replays exactly: SIM_SEED=<seed>.
class PaymentSimulation
  ACTIONS = { run_job: 10, deliver_webhook: 5, create: 3, capture: 2, refund: 2, cancel: 1, sweep: 1, expire: 0.2 }.freeze
  TOTAL_WEIGHT = ACTIONS.values.sum

  class Violation < StandardError; end

  Outcome = Struct.new(:seed, :violation, :steps, keyword_init: true) do
    def ok? = violation.nil?
    def report = "#{violation}\n  replay: SIM_SEED=#{seed}\n  last steps: #{steps.last(15).join(' ')}"
  end

  attr_reader :psp

  # `travel_to` is the example's time helper; `jobs` the ActiveJob test adapter.
  def initialize(seed:, merchant:, travel_to:, jobs:)
    @seed = seed
    @rng = Random.new(seed)
    @psp = SimPsp.new(@rng)
    @merchant = merchant
    @travel_to = travel_to
    @jobs = jobs
    @now = Time.utc(2026, 9, 1, 12)
    @log = []
    @requested = Hash.new(0) # capture amounts merchants asked for, per payment
  end

  def run(steps:)
    @jobs.enqueued_jobs.clear
    steps.times do |n|
      tick!
      action = pick_action
      @log << "#{n}:#{action}"
      send(:"do_#{action}")
      check_always!
    end
    settle!
    check_settled!
    Outcome.new(seed: @seed, steps: @log)
  rescue Violation => e
    Outcome.new(seed: @seed, violation: e.message, steps: @log)
  end

  private

  def tick!(by = nil)
    @now += by || case @rng.rand
                  when 0...0.70 then @rng.rand(0.001..2.0)
                  when 0.70...0.97 then @rng.rand(2.0..180.0)
                  else @rng.rand(1800.0..(7 * 86_400.0)) # a long quiet spell: sweepers, expiry
                  end
    @travel_to.call(@now)
  end

  def pick_action
    roll = @rng.rand * TOTAL_WEIGHT
    ACTIONS.each { |action, weight| return action if (roll -= weight).negative? }
    :run_job
  end

  # ── Actions ──────────────────────────────────────────────────────────────

  def do_create
    CreatePayment.call(@merchant, CreatePayment::Params.new(amount_minor: @rng.rand(500..20_000), currency: "EUR",
                                                            payment_method_token: "tok_visa"))
  end

  # One due job, chosen at random: jobs run in any order. One time in ten it
  # runs twice, as after a worker crash between commit and ack.
  def do_run_job
    job = due_jobs.then { |due| due[@rng.rand(due.size)] unless due.empty? } or return
    @jobs.enqueued_jobs.delete(job)
    execute(job)
    execute(job) if @rng.rand < 0.1
  end

  def due_jobs = @jobs.enqueued_jobs.select { |job| job[:at].nil? || job[:at] <= @now.to_f }

  def execute(job)
    ActiveJob::Base.execute(job)
  rescue PspAdapter::TimedOut, PspAdapter::Unavailable
    # Escaped the job: Sidekiq retries it later. Anything else escaping is a
    # bug, and propagates out of the run.
    @jobs.enqueued_jobs << job.merge(at: (@now + 60).to_f)
  end

  # A webhook in no particular order; sometimes left in place to arrive again.
  def do_deliver_webhook
    return if @psp.outbox.empty?

    index = @rng.rand(@psp.outbox.size)
    receive_webhook(@rng.rand < 0.8 ? @psp.outbox.delete_at(index) : @psp.outbox[index])
  end

  def receive_webhook(event) # what WebhooksController does once the signature is verified
    record = InboundEvent.create!(
      psp_name: "nordpay", external_id: event["id"], event_type: event["type"], psp_reference: event.dig("data", "reference"),
      payload: event, signature_valid: true, psp_timestamp: Time.iso8601(event["created_at"]), received_at: Time.current
    )
    ProcessInboundEventJob.perform_later(record.id)
  rescue ActiveRecord::RecordNotUnique
    nil # a duplicate: already stored
  end

  def do_capture
    payment = random_payment("authorized") or return
    remaining = payment.amount_minor - Ledger.captured_minor(payment)
    amount = @rng.rand < 0.5 ? nil : @rng.rand(1..[remaining, 1].max)
    CapturePayment.call(payment, amount_minor: amount)
    @requested[payment.id] += amount || remaining # counted once the API accepted it
  rescue ApiError
    nil
  end

  def do_refund
    payment = random_payment("captured", "part_refunded") or return
    CreateRefund.call(payment, amount_minor: @rng.rand < 0.3 ? nil : @rng.rand(1..payment.amount_minor))
  rescue ApiError
    nil
  end

  def do_cancel
    payment = random_payment("authorized") or return
    CancelPayment.call(payment)
  rescue ApiError, PspAdapter::Unavailable, PspAdapter::TimedOut
    nil
  end

  def do_sweep = StuckPaymentSweeperJob.perform_now
  def do_expire = ExpireAuthorizationsJob.perform_now

  # Always a fresh query: an association once iterated answers from its cache.
  def payments = Payment.where(merchant_id: @merchant.id)

  def random_payment(*states)
    candidates = payments.where(state: states).order(:id).to_a
    candidates[@rng.rand(candidates.size)] unless candidates.empty?
  end

  # ── Settling: faults off, drain everything ───────────────────────────────

  def settle!
    @psp.faults = false
    60.times do
      receive_webhook(@psp.outbox.shift) until @psp.outbox.empty?
      do_run_job until due_jobs.empty?
      break if quiet?

      tick!(31.minutes.to_f)
      do_sweep
    end
  end

  def quiet?
    @jobs.enqueued_jobs.empty? && @psp.outbox.empty? &&
      payments.where(state: PaymentStateMachine::STUCK_CANDIDATES).none? &&
      Refund.where(payment: payments, state: "pending").none? && Capture.where(payment: payments, state: "pending").none?
  end

  # ── Invariants ───────────────────────────────────────────────────────────

  def violation!(message) = raise(Violation, message)

  # True at every instant, faults or not.
  def check_always!
    violation!("unbalanced ledger transfers") if Ledger.unbalanced_transfer_ids.any?
    stray = @psp.charges.keys - payments.pluck(:psp_reference)
    violation!("the PSP holds charges for references we never created: #{stray}") if stray.any?

    payments.find_each do |p|
      captured = Ledger.captured_minor(p)
      refunded = Ledger.refunded_minor(p)
      reserved = Ledger.reserved_minor(p)
      psp_captured = @psp.captured_for(p.psp_reference)
      where = "payment #{p.id} (#{p.state})"
      violation!("#{where}: captured #{captured} > authorized #{p.amount_minor}") if captured > p.amount_minor
      violation!("#{where}: refunded #{refunded} + reserved #{reserved} > captured #{captured}") if refunded + reserved > captured
      # The customer is charged no more than the merchant asked to capture.
      violation!("#{where}: PSP captured #{psp_captured}, merchant asked for #{@requested[p.id]}") if psp_captured > @requested[p.id]
      # We never book money the PSP did not move.
      violation!("#{where}: ledger captured #{captured} > PSP #{psp_captured}") if captured > psp_captured
      violation!("#{where}: ledger refunded #{refunded} > PSP #{@psp.refunded_for(p.psp_reference)}") if refunded > @psp.refunded_for(p.psp_reference)
    end
  end

  # Once quiet: nothing ambiguous left, and our books equal the PSP's truth.
  def check_settled!
    unless quiet?
      violation!("did not settle: #{@jobs.enqueued_jobs.size} jobs, #{@psp.outbox.size} webhooks, " \
                 "states #{payments.group(:state).count}")
    end
    payments.find_each do |p|
      where = "payment #{p.id} (#{p.state})"
      violation!("#{where}: ledger captured != PSP captured") if Ledger.captured_minor(p) != @psp.captured_for(p.psp_reference)
      violation!("#{where}: ledger refunded != PSP refunded") if Ledger.refunded_minor(p) != @psp.refunded_for(p.psp_reference)
      violation!("#{where}: a reservation outlived its refund") unless Ledger.reserved_minor(p).zero?
    end
    owed = payments.sum { |p| Ledger.captured_minor(p) - Ledger.refunded_minor(p) }
    balance = Ledger.balances(@merchant).fetch("EUR", 0)
    violation!("merchant balance #{balance} != captured - refunded #{owed}") if balance != owed
  end
end
