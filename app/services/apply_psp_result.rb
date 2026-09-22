# typed: strict
# frozen_string_literal: true

# Maps a PSP's answer about a charge onto the state machine. Used by
# AuthorizePaymentJob (we asked), the stuck-payment sweeper (we polled) and
# anything else that learns a charge's state from the PSP directly.
#
# `T.absurd` makes the case exhaustive: add a Status member without
# handling it here and srb tc fails.
class ApplyPspResult
  extend T::Sig

  sig { params(payment: Payment, result: PspAdapter::Result, source: String).void }
  def self.call(payment, result, source:)
    new(payment, result, source).call
  end

  sig { params(payment: Payment, result: PspAdapter::Result, source: String).void }
  def initialize(payment, result, source)
    @payment = payment
    @result = result
    @source = source
  end

  sig { void }
  def call
    meta = { "psp_charge_id" => @result.psp_charge_id }
    ts = @result.psp_timestamp
    status = @result.status

    case status
    when PspAdapter::Result::Status::Authorized
      move(:authorized, ts, meta)

    when PspAdapter::Result::Status::RequiresAction
      move(:requires_action, ts, meta.merge("redirect_url" => @result.redirect_url))

    when PspAdapter::Result::Status::Captured
      # The PSP collapsed authorize+capture (Nordpay capture_on_authorize, or
      # Kiripay always). Our model has no pending → captured edge, and that is
      # right: money was held before it was taken. Record both, the authorize
      # 1ms earlier so history reads in causal order; then book the money.
      unless %w[authorized captured part_refunded refunded].include?(@payment.reload.state)
        move(:authorized, ts - 0.001, meta)
      end
      captured = @result.raw.fetch("captured_minor", @payment.amount_minor).to_i
      BookCapture.call(@payment, psp_captured_minor: captured, psp_timestamp: ts, source: @source, metadata: meta)

    when PspAdapter::Result::Status::Canceled
      move(:authorized, ts - 0.001, meta) if @payment.reload.state == "pending"
      move(:canceled, ts, meta)

    when PspAdapter::Result::Status::Declined
      # HTTP 200 + declined: transport success, domain failure.
      move(:failed, ts, meta.merge("decline_code" => @result.decline_code))

    when PspAdapter::Result::Status::NotFound
      # Callers turn NotFound into a re-send BEFORE calling us. Reaching here
      # is a logic error, not a PSP condition. Fail loudly.
      raise ArgumentError, "NotFound reached ApplyPspResult for payment #{@payment.id}"

    else
      T.absurd(status)
    end
  end

  private

  # A transition that tolerates being beaten to the same state by another
  # writer (webhook vs worker vs sweeper). "Already there" is not an error;
  # any OTHER illegal edge is a real bug and propagates.
  sig do
    params(to: Symbol, sort_key: T.any(Time, ActiveSupport::TimeWithZone), metadata: T::Hash[String, T.untyped]).void
  end
  def move(to, sort_key, metadata)
    @payment.transition!(to, sort_key: sort_key, source: @source, metadata: metadata)
  rescue PaymentStateMachine::IllegalTransition => e
    raise unless @payment.reload.state == to.to_s

    Rails.logger.info({ event: "psp_result.already_in_state", payment_id: @payment.id, state: to, detail: e.message }.to_json)
  end
end
