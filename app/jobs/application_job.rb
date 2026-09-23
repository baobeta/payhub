# typed: true
# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  extend T::Sig

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # One JSON line per job, with the same keys as request lines so that
  # `grep '"payment_id":"<id>"'` spans web and worker (see lograge.rb).
  around_perform do |job, block|
    carrier = { "traceparent" => job.enqueued_traceparent }.compact
    Tracing.with_context(carrier) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ctx = job.log_context
      error = nil
      begin
        block.call
      rescue StandardError => e
        error = "#{e.class}: #{e.message}"[0, 300]
        raise
      ensure
        trace_ids = Tracing.ids
        Rails.logger.info({
          time: Time.current.utc.iso8601(3), kind: "job", job: job.class.name, job_id: job.job_id,
          request_id: job.enqueued_request_id, queue: job.queue_name, attempt: job.executions,
          trace_id: trace_ids[:trace_id], span_id: trace_ids[:span_id],
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1),
          error: error
        }.merge(ctx).compact.to_json)
      end
    end
  end

  # Carry the originating request's id into the job so the two log lines join.
  attr_accessor :enqueued_request_id, :enqueued_traceparent

  def serialize
    super.merge(
      "enqueued_request_id" => enqueued_request_id || Current.request_id,
      "enqueued_traceparent" => enqueued_traceparent || Current.traceparent
    )
  end

  def deserialize(job_data)
    super
    self.enqueued_request_id = job_data["enqueued_request_id"]
    self.enqueued_traceparent = job_data["enqueued_traceparent"]
  end

  # Best effort: find the payment / merchant / psp this job is about from its
  # first argument, without loading it twice if the job already will.
  sig { returns(T::Hash[Symbol, T.untyped]) }
  def log_context
    arg = arguments.first
    return {} unless arg.is_a?(String)

    payment = case self
    when RefundPaymentJob then Refund.find_by(id: arg)&.payment
    when ProcessInboundEventJob
      ev = InboundEvent.find_by(id: arg)
      ev && Payment.find_by(psp_name: ev.psp_name, psp_reference: ev.psp_reference)
    else Payment.find_by(id: arg)
    end
    return {} unless payment

    { payment_id: payment.id, merchant_id: payment.merchant_id, psp_name: payment.psp_name }
  end
end
