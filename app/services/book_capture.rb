# typed: strict
# frozen_string_literal: true

# Books captured money in the ledger from a PSP's reported running total.
# Shared by CapturePaymentJob (Nordpay: we asked) and the inbound webhook
# processor (Kiripay: the customer approved and the PSP told us).
#
# Idempotent by comparison, not by memory: book only what the PSP has
# captured beyond what the ledger already holds. A re-run books nothing.
class BookCapture
  extend T::Sig

  sig do
    params(payment: Payment, psp_captured_minor: Integer, psp_timestamp: T.any(Time, ActiveSupport::TimeWithZone),
           source: String, metadata: T::Hash[String, T.untyped]).void
  end
  def self.call(payment, psp_captured_minor:, psp_timestamp:, source:, metadata: {})
    payment.with_lock do
      booked = Ledger.captured_minor(payment)
      delta = psp_captured_minor - booked
      next if delta <= 0

      if psp_captured_minor > payment.amount_minor
        # The PSP claims more than we authorized. Book what we authorized and
        # leave the excess for reconciliation to shout about; never silently
        # credit a merchant with money we did not agree to take.
        Rails.logger.error({ event: "capture.exceeds_authorized", payment_id: payment.id,
                             psp_captured_minor: psp_captured_minor, authorized: payment.amount_minor }.to_json)
        delta = [payment.amount_minor - booked, 0].max
        next if delta.zero?
      end

      Ledger.record_capture!(payment, delta)
      payment.update_column(:captured_minor, booked + delta) # display cache; ledger is truth

      next unless payment.state == "authorized"

      payment.transition!(:captured, sort_key: psp_timestamp, source: source,
                                     metadata: metadata.merge("captured_minor" => booked + delta))
    end
  end
end
