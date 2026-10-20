# typed: strict
# frozen_string_literal: true

# Releases authorization holds nobody captured (DECISIONS #14).
#
# An `authorized` payment holds the customer's money at their bank. If the
# merchant never captures or cancels it — they abandoned the order, or the
# payment only resolved from `unknown` after they had given up — the hold
# would sit there until the card network drops it, and nobody would tell
# the merchant. After HOLD_LIMIT without activity we void it ourselves,
# through the same CancelPayment path as the API, and the merchant gets the
# usual payment.canceled event with reason authorization_expired.
#
# "Without activity" is updated_at: a state change or a capture request
# (CapturePayment touches the row) restarts the clock. A void that fails is
# retried on the sweeper's backoff via next_check_at, so one payment the PSP
# refuses to void cannot block the rest (#13).
class ExpireAuthorizationsJob < ApplicationJob
  extend T::Sig

  queue_as :sweepers

  # Card-not-present authorizations typically lapse after 7 days; void a day
  # earlier so the release is ours, and the merchant hears about it, rather
  # than the network's silent expiry.
  HOLD_LIMIT = T.let(6.days, ActiveSupport::Duration)
  BATCH = 200

  sig { void }
  def perform
    now = Time.current
    idle = Payment.where(updated_at: ..(now - HOLD_LIMIT))
                  .where.not(id: Capture.pending.select(:payment_id)) # a capture in flight wins
                  .where("next_check_at IS NULL OR next_check_at <= ?", now)
    idle.where(state: "authorized").order(:updated_at).limit(BATCH).each { |payment| expire(payment, now) }
    # A partly captured payment still open for more captures (DECISIONS #20):
    # its captured money stays, so it is not voided; capturing is closed, and
    # the remainder lapses at the network (#14).
    idle.where(state: %w[captured part_refunded], captures_closed_at: nil).where("captured_minor < amount_minor")
        .order(:updated_at).limit(BATCH).each do |payment|
      payment.close_captures!(reason: "authorization_expired", source: "sweeper")
      Rails.logger.info({ event: "authorization.remainder_closed", payment_id: payment.id, psp_name: payment.psp_name }.to_json)
    end
  end

  private

  sig { params(payment: Payment, now: ActiveSupport::TimeWithZone).void }
  def expire(payment, now)
    unless PspRouter.adapter(payment.psp_name).supports_void?
      # Nothing we can do at this PSP: the hold lapses at the network. Say it
      # once per hold period, not every hour.
      payment.update_columns(next_check_at: now + HOLD_LIMIT)
      Rails.logger.warn({ event: "authorization.expiry_unsupported", payment_id: payment.id,
                          psp_name: payment.psp_name }.to_json)
      return
    end

    CancelPayment.call(payment, source: "sweeper", reason: "authorization_expired")
    Metrics.increment(:authorizations_expired, psp: payment.psp_name)
    Rails.logger.info({ event: "authorization.expired", payment_id: payment.id, psp_name: payment.psp_name,
                        held_for_s: (now - payment.updated_at).round }.to_json)
  rescue ApiError, PspAdapter::Unavailable, PspAdapter::TimedOut, PspAdapter::Rejected => e
    # Still authorized (or the PSP disagrees about its state): try again later,
    # and make it loud — a hold we cannot release is a customer's money.
    payment.update_columns(next_check_at: now + StuckPaymentSweeperJob.check_delay(payment.check_attempts),
                           check_attempts: payment.check_attempts + 1)
    Rails.logger.error({ event: "authorization.expiry_failed", payment_id: payment.id, psp_name: payment.psp_name,
                         error: e.class.name, detail: e.message }.to_json)
  end
end
