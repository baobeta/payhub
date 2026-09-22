# typed: strict
# frozen_string_literal: true

# Take `amount_minor` of an authorized payment at the PSP and book it.
#
# Idempotent: the ledger is the memory. On every run we compare what the PSP
# says it has captured with what our ledger says we have booked, and book only
# the difference. A re-run after a crash between the PSP call and the ledger
# write therefore books exactly once; a re-run after both wrote is a no-op.
class CapturePaymentJob < ApplicationJob
  extend T::Sig

  queue_as :payments

  retry_on PspAdapter::Unavailable, wait: :polynomially_longer, attempts: 5
  discard_on PspAdapter::Rejected

  sig { params(payment_id: String, amount_minor: Integer).void }
  def perform(payment_id, amount_minor)
    payment = Payment.find(payment_id)
    return unless %w[authorized captured].include?(payment.state)

    adapter = PspRouter.adapter(payment.psp_name)

    result = begin
      adapter.capture(payment, amount_minor)
    rescue PspAdapter::TimedOut
      # Capture may or may not have happened. The PSP's running total is the
      # truth; fetch it and reconcile against the ledger below.
      adapter.fetch(payment.psp_reference)
    end

    # Book whatever the PSP has captured that the ledger does not yet hold.
    BookCapture.call(payment, psp_captured_minor: result.raw.fetch("captured_minor", 0).to_i,
                              psp_timestamp: result.psp_timestamp, source: "worker",
                              metadata: { "psp_charge_id" => result.psp_charge_id })
  end
end
