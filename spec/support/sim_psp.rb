# typed: false
# frozen_string_literal: true

# A PSP for the deterministic simulation (spec/simulation, DECISIONS #19).
# Everything it does — which calls fail, how, which webhooks go missing or
# twice — comes from one seeded Random, so a failing run replays exactly.
#
# It honours the adapter contract the way Nordpay does: charges are keyed by
# OUR reference; a timeout may come AFTER the PSP recorded the write; status
# reads have no side effects; a charge reports `captured` only when fully
# captured. It also keeps the truth (what it really charged and refunded) so
# the simulation can hold the ledger to it.
class SimPsp < PspAdapter
  Charge = Struct.new(:reference, :amount, :status, :captured, :updated_at, keyword_init: true)
  RefundRow = Struct.new(:reference, :charge_reference, :amount, :status, :at, keyword_init: true)

  RATES = {
    unavailable: 0.08,     # refused before recording anything (5xx / connection refused)
    timeout_after: 0.12,   # recorded, then the response is lost
    read_timeout: 0.08,    # a status read times out
    decline: 0.10,
    webhook_never: 0.10,
    webhook_twice: 0.20
  }.freeze

  attr_reader :charges, :refunds, :outbox
  attr_accessor :faults

  def initialize(rng)
    super()
    @rng = rng
    @faults = true
    @charges = {}
    @refunds = {}
    @outbox = [] # webhooks sent but not yet delivered, in no particular order
  end

  def name = "nordpay"
  def currencies = %w[EUR]
  def supports_partial_refund? = true
  def separate_authorize_and_capture? = true
  def settlement_report(_date) = nil

  def authorize(payment)
    fail_before!
    charge = @charges[payment.psp_reference] ||= begin
      declined = roll(:decline)
      Charge.new(reference: payment.psp_reference, amount: payment.amount_minor, captured: 0,
                 status: declined ? "declined" : "authorized", updated_at: Time.current)
        .tap { |c| emit(c, declined ? "charge.declined" : "charge.authorized") }
    end
    fail_after!
    result(charge)
  end

  def fetch(psp_reference)
    raise TimedOut, "sim: read timed out" if roll(:read_timeout)

    charge = @charges[psp_reference]
    charge ? result(charge) : not_found(psp_reference)
  end

  # Not idempotent, like Nordpay's: a repeated capture captures again, and
  # only the authorized amount bounds it.
  def capture(payment, amount_minor)
    fail_before!
    charge = @charges.fetch(payment.psp_reference)
    raise Rejected.new(409, "sim: charge is #{charge.status}") unless %w[authorized captured].include?(charge.status)
    raise Rejected.new(422, "sim: capture exceeds authorized") if charge.captured + amount_minor > charge.amount

    charge.captured += amount_minor
    charge.status = "captured" if charge.captured == charge.amount
    charge.updated_at = Time.current
    emit(charge, "charge.captured")
    fail_after!
    result(charge)
  end

  def cancel(payment)
    fail_before!
    charge = @charges.fetch(payment.psp_reference)
    if charge.status == "authorized" && charge.captured.zero?
      charge.status = "canceled"
      charge.updated_at = Time.current
    end
    fail_after!
    result(charge)
  end

  # Idempotent on OUR refund reference, like Nordpay's X-Request-Id.
  def refund(refund)
    fail_before!
    charge = @charges.fetch(refund.payment.psp_reference)
    row = @refunds[refund.psp_reference] ||= begin
      refunded = @refunds.values.select { |r| r.charge_reference == charge.reference && r.status == "succeeded" }.sum(&:amount)
      ok = refunded + refund.amount_minor <= charge.captured
      RefundRow.new(reference: refund.psp_reference, charge_reference: charge.reference, amount: refund.amount_minor,
                    status: ok ? "succeeded" : "failed", at: Time.current)
    end
    fail_after!
    refund_result(row)
  end

  def fetch_refund(psp_reference)
    raise TimedOut, "sim: read timed out" if roll(:read_timeout)

    row = @refunds[psp_reference]
    return refund_result(row) if row

    RefundResult.new(status: RefundResult::Status::NotFound, psp_reference: psp_reference, psp_refund_id: nil,
                     failure_code: nil, psp_timestamp: Time.current)
  end

  def verify_webhook(_raw, _headers) = raise(NotImplementedError, "the simulation stores webhooks directly")

  def parse_webhook(payload)
    data = payload.fetch("data")
    WebhookEvent.new(
      external_id: payload.fetch("id"), event_type: payload.fetch("type"), psp_reference: data["reference"],
      psp_charge_id: "ch_#{data['reference']}", status: Result::Status.deserialize(data.fetch("status")),
      decline_code: nil, psp_timestamp: Time.iso8601(payload.fetch("created_at")), payload: payload
    )
  end

  # ── The truth, for the invariants ──────────────────────────────────────
  def captured_for(reference) = @charges[reference]&.captured.to_i
  def refunded_for(reference) = @refunds.values.select { |r| r.charge_reference == reference && r.status == "succeeded" }.sum(&:amount)

  private

  def roll(kind) = @faults && @rng.rand < RATES.fetch(kind)
  def fail_before! = (raise Unavailable, "sim: unavailable" if roll(:unavailable))
  def fail_after! = (raise TimedOut, "sim: recorded, response lost" if roll(:timeout_after))

  def emit(charge, type)
    return if roll(:webhook_never)

    event = { "id" => "evt_#{@rng.bytes(6).unpack1('H*')}", "type" => type, "created_at" => charge.updated_at.utc.iso8601(6),
              "data" => { "reference" => charge.reference, "status" => charge.status, "captured_minor" => charge.captured } }
    @outbox << event
    @outbox << event if roll(:webhook_twice)
  end

  def result(charge)
    Result.new(status: Result::Status.deserialize(charge.status), psp_reference: charge.reference,
               psp_charge_id: "ch_#{charge.reference}", decline_code: charge.status == "declined" ? "do_not_honor" : nil,
               psp_timestamp: charge.updated_at, raw: { "captured_minor" => charge.captured })
  end

  def not_found(reference)
    Result.new(status: Result::Status::NotFound, psp_reference: reference, psp_charge_id: nil, decline_code: nil,
               psp_timestamp: Time.current)
  end

  def refund_result(row)
    RefundResult.new(status: RefundResult::Status.deserialize(row.status), psp_reference: row.reference,
                     psp_refund_id: "re_#{row.reference}", failure_code: row.status == "failed" ? "exceeds_captured" : nil,
                     psp_timestamp: row.at)
  end
end
