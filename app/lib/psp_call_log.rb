# typed: true
# frozen_string_literal: true

# Writes one psp_calls row per outbound PSP request. Logging must never change
# payment behaviour, so a failure here is logged and counted, never raised.
#
# The row lives in the caller's transaction and dies with it if that rolls
# back, so every call also writes one structured `psp_call` log line first,
# which is shipped off the box and survives (TEST_CASES K1; PCI DSS 10.2.1 and
# 10.3: complete, protected audit logs). The line carries no body, and the path
# and error go through PspCallRedactor: never a PAN or a secret.
module PspCallLog
  extend T::Sig

  REFERENCE = /\bphr?_[a-f0-9]{24}\b/
  PSP_ID = /\bkp_[a-z0-9]+\b/ # KiriPay's own charge ids, which appear in its paths

  # params and headers are searched for our reference only and never stored
  # (headers can carry the PSP API key). NordPay sends the reference only in
  # X-Request-Id; KiriPay looks charges up by ?merchant_reference=.
  sig do
    params(
      psp: T.nilable(String), method: T.untyped, path: String,
      request_body: T.nilable(T::Hash[T.untyped, T.untyped]),
      status: T.nilable(Integer), response_body: T.untyped,
      outcome: String, started_at: T.any(Time, ActiveSupport::TimeWithZone),
      params: T::Hash[T.untyped, T.untyped], headers: T::Hash[T.untyped, T.untyped], error: T.nilable(String)
    ).void
  end
  def self.record(psp:, method:, path:, request_body:, status:, response_body:, outcome:, started_at:,
                  params: {}, headers: {}, error: nil)
    operation = PspCallRedactor.redact("#{method.to_s.upcase} #{path.gsub(REFERENCE, ':ref').gsub(PSP_ID, ':id')}")
    psp_reference = [path, params.to_json, headers.to_json, request_body.to_json].lazy.filter_map { _1[REFERENCE] }.first
    duration_ms = ((Time.current - started_at) * 1000).round
    Rails.logger.info({ event: "psp_call", psp:, method: method.to_s.upcase, path: operation, status:, outcome:,
                        duration_ms:, psp_reference:, error: error && PspCallRedactor.redact(error)[0, 500] }.to_json)
    # DECISIONS #13: no transaction (and so no row lock) is held across a PSP
    # call. Rails' test wrapper opens its transaction non-joinable, and outside
    # any transaction the current one is a non-joinable null, so "joinable"
    # means a business transaction in production and in specs alike.
    Metrics.increment(:psp_call_in_transaction, psp:) if PspCall.connection.current_transaction.joinable?

    # A savepoint: the caller may already be inside a transaction (jobs and
    # sweeps), and a failed insert must not abort that work.
    PspCall.transaction(requires_new: true) do
      PspCall.create!(
        psp_name: psp,
        operation:,
        psp_reference:,
        http_status: status,
        outcome:,
        request_redacted: PspCallRedactor.cap(PspCallRedactor.redact(request_body&.deep_stringify_keys)),
        response_redacted: PspCallRedactor.cap(PspCallRedactor.redact(response_body)),
        duration_ms:,
        sent_at: started_at
      )
    end
  rescue StandardError => e
    Rails.logger.error({ event: "psp_call_log_failed", psp:, error: e.class.name }.to_json)
    Metrics.increment(:psp_call_log_failures, psp:)
  end
end
