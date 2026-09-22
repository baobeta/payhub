# typed: true
# frozen_string_literal: true

module V1
  # POST /v1/webhooks/:psp_name — inbound from the PSPs. Unauthenticated (no
  # merchant key) but signature-verified by the PSP's adapter.
  #
  # Three outcomes, three responses:
  #   valid + new        → store, enqueue processing, 200
  #   valid + duplicate  → the unique index on (psp_name, external_id) rejects
  #                        the insert; 200 anyway so the PSP stops retrying
  #   invalid signature  → store with signature_valid: false, alert, 401,
  #                        NEVER process
  class WebhooksController < ApplicationController
    extend T::Sig

    rescue_from PspRouter::NoRoute do
      render json: { error: { code: "unknown_psp" } }, status: :not_found
    end

    sig { void }
    def create
      adapter = PspRouter.adapter(params[:psp_name].to_s)
      raw = request.raw_post
      headers = { "X-Kiripay-Signature" => request.headers["X-Kiripay-Signature"].to_s,
                  "X-Nordpay-Signature" => request.headers["X-Nordpay-Signature"].to_s }

      event = adapter.verify_webhook(raw, headers)
      record = InboundEvent.create!(
        psp_name: adapter.name, external_id: event.external_id, event_type: event.event_type,
        psp_reference: event.psp_reference, payload: event.payload, signature_valid: true,
        psp_timestamp: event.psp_timestamp, received_at: Time.current
      )
      ProcessInboundEventJob.perform_later(record.id)
      head :ok
    rescue ActiveRecord::RecordNotUnique
      # Same event again. Already stored, already (being) processed. Tell the
      # PSP "got it" or it will keep sending.
      Metrics.increment(:webhook_duplicates, psp: params[:psp_name].to_s)
      head :ok
    rescue PspAdapter::InvalidSignature => e
      InboundEvent.create!(
        psp_name: params[:psp_name].to_s, external_id: "invalid-#{SecureRandom.uuid}", event_type: "unverified",
        payload: safe_json(raw), signature_valid: false, received_at: Time.current, error: e.message
      )
      Metrics.increment(:webhook_signature_failures, psp: params[:psp_name].to_s)
      Rails.logger.error({ event: "webhook.invalid_signature", psp: params[:psp_name], detail: e.message }.to_json)
      head :unauthorized
    rescue PspAdapter::MalformedWebhook => e
      render json: { error: { code: "malformed", message: e.message } }, status: :bad_request
    end

    private

    sig { params(raw: String).returns(T::Hash[String, T.untyped]) }
    def safe_json(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      { "raw" => raw[0, 4096] }
    end
  end
end
