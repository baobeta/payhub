# typed: strict
# frozen_string_literal: true

# The contract every PSP must satisfy. The domain (services, jobs) talks only
# to this; nothing outside app/adapters knows a PSP's wire format.
#
# `abstract!` + `sig { abstract }` means a new adapter that forgets a method is
# a Sorbet error, not a NoMethodError at 3am. That is what makes the claim
# "the adapter abstraction is real" (DECISIONS #9) checkable.
class PspAdapter
  extend T::Sig
  extend T::Helpers
  abstract!

  # A PSP answered — at the transport layer. Whether the charge succeeded is a
  # separate question (`status`), because HTTP 200 + "declined" is not success.
  class Result < T::Struct
    extend T::Sig

    class Status < T::Enum
      enums do
        Authorized = new("authorized")
        Captured = new("captured")
        Canceled = new("canceled")
        Declined = new("declined")
        # The PSP created the charge but the customer must act (Kiripay redirect).
        RequiresAction = new("requires_action")
        # GET charge(ref) found nothing: our request never landed. Safe to resend.
        NotFound = new("not_found")
      end
    end

    const :status, Status
    const :psp_reference, String
    const :psp_charge_id, T.nilable(String)
    const :decline_code, T.nilable(String)
    # The PSP's own timestamp for this state — becomes payment_transitions.sort_key.
    const :psp_timestamp, T.any(Time, ActiveSupport::TimeWithZone)
    const :redirect_url, T.nilable(String), default: nil
    const :raw, T::Hash[String, T.untyped], default: {}

    sig { returns(T::Boolean) }
    def not_found? = status == Status::NotFound
  end

  # Raised on a transport-level ambiguity: the request MAY have been received.
  # The caller must move the payment to `unknown` and resolve by `fetch`.
  class TimedOut < StandardError; end

  # Raised when the PSP is definitively unreachable or answered 5xx. Safe to
  # retry with the same reference, because the PSP did not process the request
  # (5xx) or never saw it (connection refused).
  class Unavailable < StandardError; end

  # Raised when the PSP rejects the request as malformed (4xx other than 404).
  # Retrying will not help; it is a bug on our side.
  class Rejected < StandardError
    extend T::Sig
    sig { returns(Integer) }
    attr_reader :http_status

    sig { params(http_status: Integer, message: String).void }
    def initialize(http_status, message)
      @http_status = http_status
      super(message)
    end
  end

  sig { abstract.returns(String) }
  def name; end

  # Create the charge. Must send `payment.psp_reference` as the PSP-side
  # idempotency key where the PSP supports one.
  sig { abstract.params(payment: Payment).returns(Result) }
  def authorize(payment); end

  # The read that resolves `unknown`. Never has side effects.
  sig { abstract.params(psp_reference: String).returns(Result) }
  def fetch(psp_reference); end

  # Take some or all of an authorized amount. Returns the charge's new state;
  # `captured_minor` in `raw` is the PSP's running total, which the caller
  # compares against its own ledger rather than trusting blindly.
  sig { abstract.params(payment: Payment, amount_minor: Integer).returns(Result) }
  def capture(payment, amount_minor); end

  # Release an authorization hold. Idempotent on the PSP side: voiding twice
  # is harmless, so the caller may retry on ambiguity.
  sig { abstract.params(payment: Payment).returns(Result) }
  def cancel(payment); end

  # Outcome of a refund request, keyed by OUR refund reference so a timeout
  # can be resolved by `fetch_refund`, exactly as charges are by `fetch`.
  class RefundResult < T::Struct
    class Status < T::Enum
      enums do
        Succeeded = new("succeeded")
        Failed = new("failed")
        Pending = new("pending")
        NotFound = new("not_found")
      end
    end

    const :status, Status
    const :psp_reference, String
    const :psp_refund_id, T.nilable(String)
    const :failure_code, T.nilable(String)
    const :psp_timestamp, T.any(Time, ActiveSupport::TimeWithZone)
    const :raw, T::Hash[String, T.untyped], default: {}
  end

  sig { abstract.params(refund: Refund).returns(RefundResult) }
  def refund(refund); end

  sig { abstract.params(psp_reference: String).returns(RefundResult) }
  def fetch_refund(psp_reference); end

  # ── Inbound webhooks ────────────────────────────────────────────────────

  # A verified, normalised inbound event. `psp_reference` is OUR reference
  # (the one we sent), resolved from whatever the PSP calls it.
  class WebhookEvent < T::Struct
    const :external_id, String        # the PSP's event id — dedupe key
    const :event_type, String         # PSP's own name, e.g. charge.captured
    const :psp_reference, T.nilable(String)
    const :psp_charge_id, T.nilable(String)
    const :status, T.nilable(Result::Status) # what the charge is now, if the event says
    const :decline_code, T.nilable(String)
    const :psp_timestamp, T.any(Time, ActiveSupport::TimeWithZone) # ordering key
    const :payload, T::Hash[String, T.untyped]
  end

  class InvalidSignature < StandardError; end
  class MalformedWebhook < StandardError; end

  # Verify the signature with secure_compare, then parse. Raises InvalidSignature
  # (store, alert, 401, never process) or MalformedWebhook (400).
  sig { abstract.params(raw_body: String, headers: T::Hash[String, String]).returns(WebhookEvent) }
  def verify_webhook(raw_body, headers); end

  # Parse an already-verified payload (the stored inbound_events.payload).
  # No signature check here — that happened once, at receipt.
  sig { abstract.params(payload: T::Hash[String, T.untyped]).returns(WebhookEvent) }
  def parse_webhook(payload); end

  # Capability flags. The domain asks; the adapter declares.
  sig { abstract.returns(T::Boolean) }
  def supports_partial_refund?; end

  sig { abstract.returns(T::Boolean) }
  def separate_authorize_and_capture?; end

  sig { abstract.returns(T::Array[String]) }
  def currencies; end
end
