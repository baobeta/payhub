# typed: true
# frozen_string_literal: true

# What the merchant sees, plus what only we have: every call we made to the
# PSP (psp_calls, redacted), every webhook the PSP sent (inbound_events,
# signature valid or not), and the proposals raised against the payment.
module OpsPaymentDetail
  def self.call(payment)
    PaymentSerializer.call(payment).merge(
      "merchant" => { "id" => payment.merchant_id, "name" => T.must(payment.merchant).name,
                      "livemode" => T.must(payment.merchant).livemode },
      "timeline" => PaymentTimeline.call(payment),
      "psp_calls" => psp_calls(payment),
      "inbound_events" => inbound_events(payment),
      "proposals" => proposals(payment)
    )
  end

  def self.psp_calls(payment)
    PspCall.where(psp_name: payment.psp_name, psp_reference: payment.psp_reference).order(:sent_at).map do |c|
      c.slice(:operation, :http_status, :outcome, :duration_ms, :request_redacted, :response_redacted)
       .merge("sent_at" => c.sent_at.utc.iso8601(3))
    end
  end

  def self.inbound_events(payment)
    InboundEvent.where(psp_name: payment.psp_name, psp_reference: payment.psp_reference).order(:received_at).map do |e|
      e.slice(:event_type, :signature_valid, :error)
       .merge("payload" => PspCallRedactor.redact(e.payload),
              "received_at" => e.received_at.utc.iso8601(3),
              "processed_at" => e.processed_at&.utc&.iso8601(3))
    end
  end

  def self.proposals(payment)
    OperatorProposal.where(payment:).order(:created_at).map do |pr|
      { "id" => pr.id, "kind" => pr.kind, "state" => pr.state, "reason_code" => pr.reason_code,
        "case_reference" => pr.case_reference, "proposed_by" => T.must(pr.proposed_by).email,
        "decided_by" => pr.decided_by&.email, "created_at" => pr.created_at.utc.iso8601(3),
        "decided_at" => pr.decided_at&.utc&.iso8601(3) }
    end
  end
end
