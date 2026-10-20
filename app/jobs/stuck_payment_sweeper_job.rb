# typed: strict
# frozen_string_literal: true

# The safety net for everything the real-time path could not finish.
#
# Runs every minute. For each payment stuck in `pending` or `unknown` past
# STUCK_AFTER, asks the PSP by our reference and applies the answer — the
# same read that AuthorizePaymentJob uses after a timeout. Ends payments left
# in `requires_action` past REQUIRES_ACTION_TIMEOUT (the customer walked
# away: DECISIONS #10, "abandonment is failed, not ambiguity"). Also re-drives
# refunds left pending by a timeout, and re-enqueues inbound webhooks that
# arrived before their payment row existed.
#
# Scheduling (DECISIONS #13): each payment carries next_check_at. A sweep
# claims due rows with FOR UPDATE SKIP LOCKED and pushes their next check out
# by an exponential backoff BEFORE polling, so a poll that fails cannot keep
# a payment at the head of the queue. Half the batch is the longest-overdue
# (nothing waits forever); half is the least-polled, most recently due (a
# payment that just went unknown is polled within a minute, whatever backlog
# is ahead of it).
#
# Locking (DECISIONS #7): the PSP call happens with NO row lock held.
# transition! locks only for the write; if another writer resolved the
# payment meanwhile, ApplyPspResult's already-there tolerance absorbs it.
#
# Alerting: anything stuck past ALERT_AFTER is logged at ERROR with
# event=alert.stuck_payment and counted. The unknown_state_payments gauge is
# set on every sweep so a dashboard shows the backlog, not just the rate.
class StuckPaymentSweeperJob < ApplicationJob
  extend T::Sig

  queue_as :sweepers

  STUCK_AFTER = T.let(2.minutes, ActiveSupport::Duration)
  ALERT_AFTER = T.let(15.minutes, ActiveSupport::Duration) # "any payment stuck in pending or unknown for more than 15 minutes"
  BATCH = 200
  # A customer sent to a wallet or 3DS page who has not come back by now has
  # walked away. Measured from updated_at, which only a state change moves.
  REQUIRES_ACTION_TIMEOUT = T.let(30.minutes, ActiveSupport::Duration)
  # An inbound webhook whose payment has not appeared after this never will.
  ORPHAN_WINDOW = T.let(24.hours, ActiveSupport::Duration)
  # The same schedule as Payment::DUE_AT_SQL, first due after the timeout.
  ABANDONED_DUE_AT_SQL = T.let(
    "COALESCE(next_check_at, updated_at + interval '#{REQUIRES_ACTION_TIMEOUT.to_i} seconds')".freeze, String
  )
  # PSP answers about a requires_action charge that are a real outcome.
  VERDICTS = T.let(
    [PspAdapter::Result::Status::Authorized, PspAdapter::Result::Status::Captured,
     PspAdapter::Result::Status::Declined].freeze,
    T::Array[PspAdapter::Result::Status]
  )
  BACKOFF_BASE = T.let(1.minute, ActiveSupport::Duration)
  BACKOFF_CAP = T.let(30.minutes, ActiveSupport::Duration)

  # 1, 2, 4, 8, 16, then every 30 minutes, with ±20% jitter so a batch that
  # failed together (a PSP outage) does not come back together.
  sig { params(attempts: Integer).returns(Float) }
  def self.check_delay(attempts)
    [BACKOFF_BASE.to_f * (2**[attempts, 10].min), BACKOFF_CAP.to_f].min * rand(0.8..1.2)
  end

  # Operator entry point (RUNBOOK §4): poll one payment now, whatever its backoff.
  sig { params(payment: Payment).void }
  def self.poll_now(payment)
    new.send(:resolve, payment)
  end

  sig { void }
  def perform
    sweep_payments
    expire_abandoned_actions
    redrive_captures
    redrive_refunds
    redrive_orphan_webhooks
    expire_idempotency_keys
  end

  private

  sig { void }
  def sweep_payments
    Metrics.gauge(:unknown_state_payments, Payment.where(state: "unknown").count)

    claim_due(Time.current).each do |payment|
      age = Time.current - payment.updated_at
      if age > ALERT_AFTER
        # The one alert that would actually page someone.
        Rails.logger.error({ event: "alert.stuck_payment", payment_id: payment.id, state: payment.state,
                             psp_name: payment.psp_name, stuck_for_s: age.round }.to_json)
        Metrics.increment(:stuck_payment_alerts, psp: payment.psp_name, state: payment.state)
      end
      resolve(payment)
    end
  end

  # Claims up to BATCH due payments and reschedules each before any PSP call.
  # The lock is held only for this short transaction, never across HTTP.
  sig do
    params(now: ActiveSupport::TimeWithZone, scope: ActiveRecord::Relation, due_at_sql: String)
      .returns(T::Array[Payment])
  end
  def claim_due(now, scope = Payment.due_for_check(now), due_at_sql = Payment::DUE_AT_SQL)
    Payment.transaction do
      due = scope.lock("FOR UPDATE SKIP LOCKED")
      overdue = due.order(Arel.sql("#{due_at_sql} ASC")).limit(BATCH / 2).to_a
      fresh = due.where.not(id: overdue.map(&:id))
                 .order(:check_attempts, Arel.sql("#{due_at_sql} DESC"))
                 .limit(BATCH - overdue.size).to_a

      (overdue + fresh).each do |payment|
        payment.update_columns(next_check_at: now + self.class.check_delay(payment.check_attempts),
                               check_attempts: payment.check_attempts + 1)
      end
    end
  end

  # `requires_action` payments whose customer has not come back, scheduled
  # and claimed exactly like stuck ones (DECISIONS #13), without the stuck
  # alert: a customer who walks away is normal, not an incident.
  sig { void }
  def expire_abandoned_actions
    now = Time.current
    due = Payment.where(state: "requires_action").where("#{ABANDONED_DUE_AT_SQL} <= ?", now)
    claim_due(now, due, ABANDONED_DUE_AT_SQL).each { |payment| resolve(payment) }
  end

  sig { params(payment: Payment).void }
  def resolve(payment)
    adapter = PspRouter.adapter(payment.psp_name)
    result = if payment.state == "requires_action"
               abandoned_verdict(payment, adapter)
             else
               ResolveUnknownPayment.call(payment, adapter)
             end
    return unless result

    ApplyPspResult.call(payment, result, source: "sweeper")
  rescue PspAdapter::Unavailable, PspAdapter::TimedOut, PspAdapter::Rejected => e
    # Unavailable/TimedOut: try next sweep. Rejected: our bug, alert. Neither
    # should stop the batch. Another writer getting there first is not an
    # error at all: every write takes the row lock (with_lock reloads it, so
    # no StaleObjectError), and ApplyPspResult treats "already there" as done.
    Rails.logger.warn({ event: "sweeper.skip", payment_id: payment.id, error: e.class.name, detail: e.message }.to_json)
  end

  # The customer was sent to the PSP's page and has not come back. Ask the
  # PSP (never re-send: the charge exists). A verdict it has reached applies
  # as the webhook would have: captured is booked, declined fails. Still
  # waiting, or gone, past the timeout: the customer walked away.
  sig { params(payment: Payment, adapter: PspAdapter).returns(T.nilable(PspAdapter::Result)) }
  def abandoned_verdict(payment, adapter)
    result = adapter.fetch(payment.psp_reference)
    Metrics.increment(:psp_calls, psp: adapter.name, operation: "fetch", outcome: result.status.serialize)
    return result if VERDICTS.include?(result.status)
    return nil if Time.current - payment.updated_at < REQUIRES_ACTION_TIMEOUT # an operator's early poll_now

    Rails.logger.info({ event: "sweeper.customer_action_expired", payment_id: payment.id, psp_name: payment.psp_name,
                        psp_status: result.status.serialize }.to_json)
    PspAdapter::Result.new(status: PspAdapter::Result::Status::Declined, psp_reference: payment.psp_reference, psp_charge_id: result.psp_charge_id,
                           decline_code: "customer_action_expired", psp_timestamp: Time.current)
  end

  # A capture left `pending` past the stuck threshold: its job exhausted its
  # retries, or never ran. CapturePaymentJob reads the PSP before it sends,
  # so re-running it can never capture twice (DECISIONS #20).
  sig { void }
  def redrive_captures
    Capture.pending.where(updated_at: ..STUCK_AFTER.ago).order(:updated_at).limit(BATCH).pluck(:id).each do |id|
      CapturePaymentJob.perform_later(id)
    end
  end

  # A refund left `pending` past the stuck threshold had its job time out on
  # both the send and the read-back, or its job never ran. RefundPaymentJob
  # is idempotent (it stops if the row is no longer pending) and resolves a
  # timeout by fetch_refund, so simply enqueue it again.
  sig { void }
  def redrive_refunds
    Refund.where(state: "pending").where(updated_at: ..STUCK_AFTER.ago).limit(BATCH).pluck(:id).each do |id|
      RefundPaymentJob.perform_later(id)
    end
  end

  # Webhooks that arrived before our worker wrote the payment row were left
  # unprocessed (ProcessInboundEventJob logged webhook.orphan). Try again;
  # the payment probably exists now. Half the batch is the oldest, half the
  # newest, so a backlog cannot starve a new orphan (the payment-sweep
  # fairness rule, DECISIONS #13). Past ORPHAN_WINDOW the payment is not
  # coming: the event is closed with an error and an alert, not retried forever.
  sig { void }
  def redrive_orphan_webhooks
    abandon_old_orphans

    live = InboundEvent.unprocessed.where(received_at: ORPHAN_WINDOW.ago..1.minute.ago)
    oldest = live.limit(BATCH / 2).pluck(:id)
    newest = live.where.not(id: oldest).reorder(received_at: :desc).limit(BATCH - oldest.size).pluck(:id)
    (oldest + newest).each { |id| ProcessInboundEventJob.perform_later(id) }
  end

  # Only events whose payment still does not exist: an unprocessed event for a
  # payment we do have is a processing failure, which Sidekiq's retries own.
  sig { void }
  def abandon_old_orphans
    has_payment = Payment.where("payments.psp_name = inbound_events.psp_name")
                         .where("payments.psp_reference = inbound_events.psp_reference")
    old = InboundEvent.unprocessed.where(received_at: ...ORPHAN_WINDOW.ago).where.not(has_payment.arel.exists)
    old.limit(BATCH).each do |event|
      event.update!(processed_at: Time.current, error: "orphan: no payment for reference")
      Rails.logger.error({ event: "webhook.orphan_abandoned", inbound_event_id: event.id, psp_name: event.psp_name,
                           psp_reference: event.psp_reference, received_at: event.received_at.utc.iso8601 }.to_json)
      Metrics.increment(:orphan_webhooks_abandoned, psp: event.psp_name)
    end
  end

  # Keys are reusable after TTL; delete the rows so the table does not grow forever.
  sig { void }
  def expire_idempotency_keys
    # Postgres has no DELETE ... LIMIT; bound the batch via a subquery.
    deleted = IdempotencyKey.where(id: IdempotencyKey.expired.limit(1000).select(:id)).delete_all
    Rails.logger.info({ event: "idempotency_keys.expired", deleted: deleted }.to_json) if deleted.positive?
  end
end
