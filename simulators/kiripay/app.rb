# frozen_string_literal: true

require "sinatra/base"
require "json"
require "yaml"
require "securerandom"
require "openssl"
require "net/http"
require "time"

# Kiripay simulator: SEA e-wallets. Capture-only (no authorize step),
# confirmation by redirect then WEBHOOK ONLY, full refunds only, VND has no
# minor unit, and NO idempotency header — a repeated POST /charges creates a
# second charge. The client must dedupe on its own merchant_reference.
#
# Amounts on the wire are MAJOR units as strings ("25.00" THB, "500000" VND).
#
# Flow:  POST /charges → { status: "pending_redirect", redirect_url }
#        customer approves (POST /_sim/charges/:id/approve in tests)
#        → simulator POSTs a signed webhook to PAYHUB_WEBHOOK_URL
#           charge.created (ts0) then charge.captured (ts1) — or, when
#           misbehaving: duplicated, reversed, late, unsigned, or never.
module Kiripay
  class Store
    Charge = Struct.new(:id, :merchant_reference, :status, :code, :amount, :currency, :refunded,
                        :created_at, :captured_at, keyword_init: true) do
      def to_h
        { id: id, merchant_reference: merchant_reference, status: status, code: code, amount: amount,
          currency: currency, refunded: refunded, created_at: created_at.utc.iso8601(3),
          captured_at: captured_at&.utc&.iso8601(3) }.compact
      end
    end

    Refund = Struct.new(:id, :charge_id, :status, :code, :amount, :created_at, keyword_init: true) do
      def to_h
        { id: id, charge_id: charge_id, status: status, code: code, amount: amount,
          created_at: created_at.utc.iso8601(3) }.compact
      end
    end

    attr_reader :charges, :refunds, :sent_webhooks

    def initialize
      @charges = {}
      @refunds = {}
      @sent_webhooks = []
      @mutex = Mutex.new
    end

    def sync(&) = @mutex.synchronize(&)

    def reset!
      @charges.clear
      @refunds.clear
      @sent_webhooks.clear
    end
  end

  class App < Sinatra::Base
    CURRENCIES = %w[VND THB IDR].freeze
    API_KEY = ENV.fetch("KIRIPAY_API_KEY", "kp_test_key")
    WEBHOOK_SECRET = ENV.fetch("KIRIPAY_WEBHOOK_SECRET", "kp_whsec_test")
    WEBHOOK_URL = ENV.fetch("PAYHUB_WEBHOOK_URL", "http://localhost:3000/v1/webhooks/kiripay")
    PUBLIC_URL = ENV.fetch("KIRIPAY_PUBLIC_URL", "http://localhost:4002")

    set :store, Store.new
    set :failure, YAML.safe_load_file(File.expand_path("failure_config.yml", __dir__))
    set :show_exceptions, false
    set :logging, true
    set :protection, false
    set :host_authorization, { permitted_hosts: [] }
    set :deliver_webhooks, true # tests flip this off and inspect store.sent_webhooks

    helpers do
      def store = settings.store
      def config = settings.failure
      def json!(body, status: 200) = [status, { "Content-Type" => "application/json" }, [JSON.generate(body)]]
      def error!(status, code, message) = halt json!({ error: { code: code, message: message } }, status: status)

      def authenticate!
        error!(401, "unauthorized", "invalid api key") unless request.env["HTTP_AUTHORIZATION"] == "Bearer #{API_KEY}"
      end

      def body_json
        @body_json ||= JSON.parse(request.body.read.to_s.then { |s| s.empty? ? "{}" : s })
      rescue JSON::ParserError
        error!(400, "invalid_json", "body is not JSON")
      end

      def inject?(behaviour, forced = request.env["HTTP_X_SIM_FORCE"].to_s)
        forced_list = forced.split(",").map(&:strip)
        return true if forced_list.include?(behaviour)
        return false if forced_list.any?

        rate = config.fetch("#{behaviour}_rate", 0).to_f
        rate.positive? && rand < rate
      end

      # ── Webhook delivery ──────────────────────────────────────────────
      # Signature: HMAC-SHA256 over "#{timestamp}.#{body}" with the shared
      # secret, sent as X-Kiripay-Signature: t=<unix>,v1=<hex>.
      def sign(body, ts, secret = WEBHOOK_SECRET)
        "t=#{ts},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{ts}.#{body}")}"
      end

      def deliver(event, secret: WEBHOOK_SECRET, delay: config.fetch("webhook_delay_seconds", 0.2).to_f)
        body = JSON.generate(event)
        ts = Time.now.to_i
        headers = { "Content-Type" => "application/json", "X-Kiripay-Signature" => sign(body, ts, secret),
                    "X-Kiripay-Event-Id" => event[:id] }
        store.sync { store.sent_webhooks << { event: event, headers: headers, delay: delay } }
        return unless settings.deliver_webhooks

        Thread.new do
          sleep delay
          uri = URI(WEBHOOK_URL)
          req = Net::HTTP::Post.new(uri, headers)
          req.body = body
          Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) { |h| h.request(req) }
        rescue StandardError => e
          warn "kiripay: webhook delivery failed: #{e.class}: #{e.message}"
        end
      end

      def event_for(charge, type, at)
        { id: "evt_#{SecureRandom.hex(8)}", type: type, created_at: at.utc.iso8601(3), data: charge.to_h }
      end

      # The customer approved (or declined). Emit the webhooks, misbehaving as configured.
      def settle!(charge, force)
        if inject?("decline", force)
          store.sync do
            charge.status = "declined"
            charge.code = "wallet_declined"
          end
          deliver(event_for(charge, "charge.declined", Time.now))
          return
        end

        store.sync do
          charge.status = "captured"
          charge.captured_at = Time.now
        end
        created = event_for(charge, "charge.created", charge.created_at)
        captured = event_for(charge, "charge.captured", charge.captured_at)

        return if inject?("webhook_never", force)

        secret = inject?("webhook_bad_signature", force) ? "wrong-secret" : WEBHOOK_SECRET
        delay = config.fetch("webhook_delay_seconds", 0.2).to_f
        if inject?("webhook_late", force)
          # "6 hours late": the event timestamp is honest (when it happened);
          # only delivery is late. We simulate with a longer delay.
          delay += config.fetch("webhook_late_extra_seconds", 1.5).to_f
        end

        events = inject?("webhook_out_of_order", force) ? [captured, created] : [created, captured]
        copies = inject?("webhook_duplicate", force) ? 5 : 1
        events.each_with_index do |ev, i|
          copies.times { |c| deliver(ev, secret: secret, delay: delay + (i * 0.05) + (c * 0.02)) }
        end
      end
    end

    before { content_type :json }

    # ── Admin ────────────────────────────────────────────────────────────
    post "/_sim/reset" do
      store.sync { store.reset! }
      json!({ ok: true })
    end

    get "/_sim/charges" do
      json!(store.charges.values.map(&:to_h))
    end

    get "/_sim/webhooks" do
      json!(store.sent_webhooks)
    end

    put "/_sim/config" do
      settings.failure.merge!(body_json)
      json!(settings.failure)
    end

    # The customer pressing "approve" in their wallet app.
    post "/_sim/charges/:id/approve" do
      charge = store.charges[params[:id]]
      error!(404, "not_found", "no such charge") unless charge
      error!(409, "not_pending", "charge is #{charge.status}") unless charge.status == "pending_redirect"
      settle!(charge, body_json.fetch("force", "").to_s)
      json!(charge.to_h)
    end

    get "/healthz" do
      json!({ status: "ok", psp: "kiripay" })
    end

    # ── The PSP API ──────────────────────────────────────────────────────
    #
    # POST /charges — body: amount (MAJOR units, string), currency, wallet_token, merchant_reference
    #   200: { id, merchant_reference, status: "pending_redirect", redirect_url, amount, currency, created_at }
    #   NOTE: no idempotency. A second identical POST creates a second charge.
    post "/charges" do
      authenticate!
      body = body_json
      currency = body["currency"].to_s
      amount = body["amount"].to_s
      error!(422, "unsupported_currency", "Kiripay supports #{CURRENCIES.join(', ')}") unless CURRENCIES.include?(currency)
      error!(422, "invalid_amount", "amount must be a positive decimal string") unless amount.match?(/\A\d+(\.\d+)?\z/) && amount.to_f.positive?
      error!(422, "invalid_amount", "VND has no minor unit") if currency == "VND" && amount.include?(".")
      error!(422, "missing_reference", "merchant_reference is required") if body["merchant_reference"].to_s.empty?

      charge = Store::Charge.new(
        id: "kp_#{SecureRandom.hex(10)}", merchant_reference: body["merchant_reference"],
        status: "pending_redirect", amount: amount, currency: currency, refunded: "0", created_at: Time.now
      )
      store.sync { store.charges[charge.id] = charge }

      sleep(config.fetch("timeout_seconds", 5).to_f) if inject?("timeout")

      json!(charge.to_h.merge(redirect_url: "#{PUBLIC_URL}/pay/#{charge.id}"))
    end

    # GET /charges?merchant_reference=… — the ONLY way to find a charge by our
    # reference. Returns a list: Kiripay may have created more than one.
    get "/charges" do
      authenticate!
      ref = params["merchant_reference"].to_s
      error!(400, "missing_reference", "merchant_reference is required") if ref.empty?
      matches = store.charges.values.select { |c| c.merchant_reference == ref }.sort_by(&:created_at)
      json!({ data: matches.map(&:to_h) })
    end

    get "/charges/:id" do
      authenticate!
      charge = store.charges[params[:id]]
      error!(404, "not_found", "no such charge") unless charge
      json!(charge.to_h)
    end

    # POST /charges/:id/refunds — FULL refund only; body must be empty or amount == charge amount.
    post "/charges/:id/refunds" do
      authenticate!
      charge = store.charges[params[:id]]
      error!(404, "not_found", "no such charge") unless charge
      error!(409, "not_captured", "charge is #{charge.status}") unless charge.status == "captured"
      requested = body_json["amount"]
      error!(422, "partial_not_supported", "Kiripay refunds the full amount only") if requested && requested.to_s != charge.amount
      error!(409, "already_refunded", "charge already refunded") if charge.status == "refunded" || charge.refunded == charge.amount

      refund = Store::Refund.new(id: "kr_#{SecureRandom.hex(8)}", charge_id: charge.id, status: "succeeded",
                                 amount: charge.amount, created_at: Time.now)
      store.sync do
        store.refunds[refund.id] = refund
        charge.refunded = charge.amount
        charge.status = "refunded"
      end
      json!(refund.to_h)
    end

    get "/refunds/:id" do
      authenticate!
      refund = store.refunds[params[:id]]
      error!(404, "not_found", "no such refund") unless refund
      json!(refund.to_h)
    end

    error do
      json!({ error: { code: "internal_error", message: env["sinatra.error"].message } }, status: 500)
    end
  end
end
