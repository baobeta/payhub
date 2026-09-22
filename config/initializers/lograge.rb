# typed: false
# frozen_string_literal: true

# One JSON line per request. Fields carried on every line: request_id,
# merchant_id, payment_id, psp_name, duration_ms — so a single
#   grep '"payment_id":"<id>"' log/*.log
# reconstructs a payment's whole life across web and worker (jobs log the
# same keys from ApplicationJob).
Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new
  config.lograge.base_controller_class = "ActionController::API"

  config.lograge.custom_options = lambda do |event|
    payload = event.payload
    {
      time: Time.current.utc.iso8601(3),
      kind: "request",
      request_id: payload[:request_id],
      merchant_id: payload[:merchant_id],
      payment_id: payload[:payment_id],
      psp_name: payload[:psp_name],
      duration_ms: event.duration.round(1),
      # Rails' default `params` dump is filtered by filter_parameters, but we
      # do not log params at all: the body of a payment request has a token
      # in it, and "filtered" is one config change away from "not filtered".
      exception: payload[:exception]&.first
    }.compact
  end

  # Keep lograge's own keys short and stable; drop the ones we replace.
  config.lograge.custom_payload do |controller|
    controller.respond_to?(:log_payload, true) ? controller.send(:log_payload) : {}
  end
end
