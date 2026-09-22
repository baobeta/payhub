# typed: strict
# frozen_string_literal: true

# The safety net for everything the real-time path could not finish.
#
# Runs every minute. For each payment stuck in `pending` or `unknown` past
# STUCK_AFTER, asks the PSP by our reference and applies the answer — the
# same read that AuthorizePaymentJob uses after a timeout. Also re-drives
# refunds left pending by a timeout, and re-enqueues inbound webhooks that
# arrived before their payment row existed.
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

  sig { void }
  def perform
    sweep_payments
    redrive_refunds
    redrive_orphan_webhooks
    expire_idempotency_keys
  end

  private

  sig { void }
  def sweep_payments
    stuck = Payment.stuck(older_than: STUCK_AFTER.ago).order(:updated_at).limit(BATCH).to_a
    Metrics.gauge(:unknown_state_payments, Payment.where(state: "unknown").count)

    stuck.each do |payment|
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

  sig { params(payment: Payment).void }
  def resolve(payment)
    adapter = PspRouter.adapter(payment.psp_name)
    result = ResolveUnknownPayment.call(payment, adapter)
    return unless result

    ApplyPspResult.call(payment, result, source: "sweeper")
  rescue PspAdapter::Unavailable, PspAdapter::Rejected, ActiveRecord::StaleObjectError => e
    # Unavailable: try next sweep. Rejected: our bug, alert. Stale: someone
    # else wrote first — fine. None of these should stop the rest of the batch.
    Rails.logger.warn({ event: "sweeper.skip", payment_id: payment.id, error: e.class.name, detail: e.message }.to_json)
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
  # the payment probably exists now.
  sig { void }
  def redrive_orphan_webhooks
    InboundEvent.unprocessed.where(received_at: ..1.minute.ago).limit(BATCH).pluck(:id).each do |id|
      ProcessInboundEventJob.perform_later(id)
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
