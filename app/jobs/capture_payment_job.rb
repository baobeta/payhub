# typed: strict
# frozen_string_literal: true

# Take a Capture's amount at the PSP and book it (DECISIONS #20).
#
# The PSP's capture call is NOT idempotent: sent twice, it captures twice.
# Booking was always idempotent — the ledger books only the difference between
# the PSP's running total and its own — but that made a second capture look
# consistent, not harmless: the customer paid twice what the merchant asked.
#
# So the job reads before it writes. One capture is in flight per payment, and
# the PSP's running total only grows, so "has this capture landed?" is
# answered by that total reaching the capture's target (base + amount). A
# re-run after a crash, a Sidekiq redelivery, or a retry after a timeout
# whose follow-up read also timed out: each reads first, sees the capture
# landed, and books it instead of sending it again. The only send is one
# made after a read that says it has not landed.
class CapturePaymentJob < ApplicationJob
  extend T::Sig

  queue_as :payments

  retry_on PspAdapter::Unavailable, wait: :polynomially_longer, attempts: 5

  # `legacy_amount`: jobs enqueued before captures were rows carried
  # (payment_id, amount). They are adopted as a Capture on first run.
  sig { params(capture_id: String, legacy_amount: T.nilable(Integer)).void }
  def perform(capture_id, legacy_amount = nil)
    capture = legacy_amount ? adopt_legacy(capture_id, legacy_amount) : Capture.find(capture_id)
    return if capture.nil? || capture.state != "pending"

    payment = T.must(capture.payment)
    unless %w[authorized captured].include?(payment.state)
      return finish(capture, "failed", failure_code: "payment_#{payment.state}")
    end

    adapter = PspRouter.adapter(payment.psp_name)
    # Read first. Unavailable or TimedOut here raise: retry later, never send blind.
    result = adapter.fetch(payment.psp_reference)
    unless landed?(result, capture)
      result = begin
        adapter.capture(payment, capture.amount_minor)
      rescue PspAdapter::TimedOut
        adapter.fetch(payment.psp_reference) # a timeout here raises; the retry reads first again
      end
    end

    BookCapture.call(payment, psp_captured_minor: psp_captured(result), psp_timestamp: result.psp_timestamp,
                              source: "worker", metadata: { "psp_charge_id" => result.psp_charge_id, "capture_id" => capture.id })
    # Booked in full: done. Otherwise the capture did not land (a timeout the
    # PSP never acted on); it stays pending and the sweeper re-drives it.
    finish(capture, "succeeded") if Ledger.captured_minor(payment) >= capture.target_minor
  rescue PspAdapter::Rejected => e
    # The PSP refused (exceeds authorized, charge not capturable). Retrying
    # cannot help; the merchant hears it from the payment's state.
    finish(T.must(capture), "failed", failure_code: "psp_rejected_#{e.http_status}")
    Rails.logger.error({ event: "capture.rejected", capture_id: capture&.id, detail: e.message }.to_json)
  end

  private

  sig { params(result: PspAdapter::Result, capture: Capture).returns(T::Boolean) }
  def landed?(result, capture) = !result.not_found? && psp_captured(result) >= capture.target_minor

  sig { params(result: PspAdapter::Result).returns(Integer) }
  def psp_captured(result) = result.raw.fetch("captured_minor", 0).to_i

  sig { params(capture: Capture, state: String, failure_code: T.nilable(String)).void }
  def finish(capture, state, failure_code: nil)
    T.must(capture.payment).with_lock do
      capture.reload
      capture.update!(state: state, failure_code: failure_code) if capture.state == "pending"
    end
  end

  sig { params(payment_id: String, amount: Integer).returns(T.nilable(Capture)) }
  def adopt_legacy(payment_id, amount)
    payment = Payment.find(payment_id)
    payment.with_lock do
      payment.captures.pending.first ||
        payment.captures.create!(amount_minor: amount, base_captured_minor: Ledger.captured_minor(payment))
    end
  end
end
