# typed: true
# frozen_string_literal: true

# Writes one psp_calls row per outbound PSP request. Logging must never change
# payment behaviour, so a failure here is logged and counted, never raised.
module PspCallLog
  REFERENCE = /\bphr?_[a-f0-9]{24}\b/
  PSP_ID = /\bkp_[a-z0-9]+\b/ # KiriPay's own charge ids, which appear in its paths

  # params and headers are searched for our reference only and never stored
  # (headers can carry the PSP API key). NordPay sends the reference only in
  # X-Request-Id; KiriPay looks charges up by ?merchant_reference=.
  def self.record(psp:, method:, path:, request_body:, status:, response_body:, outcome:, started_at:,
                  params: {}, headers: {})
    # A savepoint, because CancelPayment calls the PSP while holding a row
    # lock: a failed insert must not abort the caller's transaction.
    PspCall.transaction(requires_new: true) do
      PspCall.create!(
        psp_name: psp,
        operation: "#{method.to_s.upcase} #{path.gsub(REFERENCE, ':ref').gsub(PSP_ID, ':id')}",
        psp_reference: [path, params.to_json, headers.to_json, request_body.to_json].lazy.filter_map { _1[REFERENCE] }.first,
        http_status: status,
        outcome:,
        request_redacted: PspCallRedactor.redact(request_body&.deep_stringify_keys),
        response_redacted: PspCallRedactor.redact(response_body),
        duration_ms: ((Time.current - started_at) * 1000).round,
        sent_at: started_at
      )
    end
  rescue StandardError => e
    Rails.logger.error({ event: "psp_call_log_failed", psp:, error: e.class.name }.to_json)
    Metrics.increment(:psp_call_log_failures, psp:)
  end
end
