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

    reconcile(payment, result)
  end

  private

  # Book whatever the PSP has captured that we have not yet booked.
  sig { params(payment: Payment, result: PspAdapter::Result).void }
  def reconcile(payment, result)
    psp_captured = result.raw.fetch("captured_minor", 0).to_i

    payment.with_lock do
      booked = Ledger.captured_minor(payment)
      delta = psp_captured - booked
      next if delta <= 0 # nothing new (re-run, or capture never happened)

      Ledger.record_capture!(payment, delta)
      payment.update_column(:captured_minor, psp_captured) # display cache only; ledger is truth

      if payment.state == "authorized"
        payment.transition!(:captured, sort_key: result.psp_timestamp, source: "worker",
                                       metadata: { "psp_charge_id" => result.psp_charge_id, "captured_minor" => psp_captured })
      end
    end
  end
end
