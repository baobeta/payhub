# frozen_string_literal: true

require "sinatra/base"
require "json"
require "yaml"
require "securerandom"
require "openssl"
require "net/http"
require "time"

# Nordpay simulator: EU cards, separate authorize then capture, synchronous
# confirmation, partial refunds, honours X-Request-Id for idempotency.
#
# It is deliberately unreliable. Every behaviour in failure_config.yml can also
# be forced per request with `X-Sim-Force: timeout|flaky_500|duplicate|decline`
# so PayHub's specs are deterministic.
#
# State is a plain in-memory hash keyed by X-Request-Id. That is the point:
# on a timeout the charge is REALLY recorded before the sleep, so
# GET /charges/:reference genuinely returns it afterwards.
module Nordpay
  class Store
    Charge = Struct.new(:id, :reference, :status, :code, :amount_minor, :currency,
                        :captured_minor, :attempts, :created_at, keyword_init: true) do
      def to_h
        {
          id: id, reference: reference, status: status, code: code,
          amount_minor: amount_minor, currency: currency, captured_minor: captured_minor,
          created_at: created_at.utc.iso8601(3)
        }.compact
      end
    end

    Refund = Struct.new(:id, :reference, :charge_reference, :status, :code, :amount_minor, :created_at,
                        keyword_init: true) do
      def to_h
        { id: id, reference: reference, charge_reference: charge_reference, status: status, code: code,
          amount_minor: amount_minor, created_at: created_at.utc.iso8601(3) }.compact
      end
    end

    attr_reader :refunds, :sent_webhooks

    def initialize
      @charges = {}
      @refunds = {}
      @sent_webhooks = []
      @mutex = Mutex.new
    end

    def sync(&) = @mutex.synchronize(&)
    def find(reference) = @charges[reference]
    def all = @charges.values

    def reset!
      @charges.clear
      @refunds.clear
      @sent_webhooks.clear
    end

    def find_or_create(reference)
      @charges[reference] ||= Charge.new(
        id: "ch_#{SecureRandom.hex(8)}", reference: reference, attempts: 0, captured_minor: 0,
        created_at: Time.now
      )
    end
  end

  class App < Sinatra::Base
    CURRENCIES = %w[EUR GBP USD].freeze
    API_KEY = ENV.fetch("NORDPAY_API_KEY", "np_test_key")

    WEBHOOK_SECRET = ENV.fetch("NORDPAY_WEBHOOK_SECRET", "np_whsec_test")
    WEBHOOK_URL = ENV.fetch("PAYHUB_WEBHOOK_URL", "http://localhost:3000/v1/webhooks/nordpay")

    set :store, Store.new
    set :failure, YAML.safe_load_file(File.expand_path("failure_config.yml", __dir__))
    set :show_exceptions, false
    set :logging, true
    set :deliver_webhooks, true # tests flip this off and inspect store.sent_webhooks
    # Rack::Protection guards browser sessions/cookies (CSRF, host auth). This is
    # a bearer-token JSON API with neither, and its host header varies by
    # environment (compose service name, localhost, rack-test).
    set :protection, false
    # Sinatra 4.1 also restricts Host to localhost in development; we are
    # reached as `nordpay` (compose), `localhost`, and `example.org` (rack-test).
    set :host_authorization, { permitted_hosts: [] }

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

      # Rolls the dice once per behaviour, or obeys X-Sim-Force.
      def inject?(behaviour, forced_header = request.env["HTTP_X_SIM_FORCE"].to_s)
        forced = forced_header.split(",").map(&:strip)
        return true if forced.include?(behaviour)
        return false if forced.any? # forcing one behaviour disables the random others

        rate = config.fetch("#{behaviour}_rate", 0).to_f
        rate.positive? && rand < rate
      end

      # ── Webhook delivery ──────────────────────────────────────────────
      # Signature: X-Nordpay-Signature: <hex HMAC-SHA256 of the raw body>.
      def deliver(event, secret: WEBHOOK_SECRET, delay: config.fetch("webhook_delay_seconds", 0.2).to_f)
        body = JSON.generate(event)
        headers = { "Content-Type" => "application/json", "X-Nordpay-Event-Id" => event[:id],
                    "X-Nordpay-Signature" => OpenSSL::HMAC.hexdigest("SHA256", secret, body) }
        store.sync { store.sent_webhooks << { event: event, headers: headers, delay: delay } }
        return unless settings.deliver_webhooks

        Thread.new do
          sleep delay
          uri = URI(WEBHOOK_URL)
          req = Net::HTTP::Post.new(uri, headers)
          req.body = body
          Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) { |h| h.request(req) }
        rescue StandardError => e
          warn "nordpay: webhook delivery failed: #{e.class}: #{e.message}"
        end
      end

      def event_for(charge, type, at)
        { id: "evt_#{SecureRandom.hex(8)}", type: type, created_at: at.utc.iso8601(3), data: charge.to_h }
      end

      # Emit one charge event, misbehaving as configured: duplicated ×5,
      # late, unsigned, or never. Out-of-order is emitted by the capture path,
      # which resends the earlier authorized event AFTER captured.
      def emit!(charge, type, at, forced = request.env["HTTP_X_SIM_FORCE"].to_s)
        return if inject?("webhook_never", forced)

        secret = inject?("webhook_bad_signature", forced) ? "wrong-secret" : WEBHOOK_SECRET
        delay = config.fetch("webhook_delay_seconds", 0.2).to_f
        delay += config.fetch("webhook_late_extra_seconds", 1.5).to_f if inject?("webhook_late", forced)
        copies = inject?("webhook_duplicate", forced) ? 5 : 1
        ev = event_for(charge, type, at)
        copies.times { |c| deliver(ev, secret: secret, delay: delay + (c * 0.02)) }
        ev
      end
    end

    before { content_type :json }

    # ── Admin (used by PayHub's specs; not part of the "real" PSP API) ──────
    post "/_sim/reset" do
      store.sync { store.reset! }
      json!({ ok: true })
    end

    get "/_sim/charges" do
      json!(store.all.map(&:to_h))
    end

    get "/_sim/webhooks" do
      json!(store.sent_webhooks)
    end

    put "/_sim/config" do
      settings.failure.merge!(body_json)
      json!(settings.failure)
    end

    get "/healthz" do
      json!({ status: "ok", psp: "nordpay" })
    end

    # ── The PSP API ────────────────────────────────────────────────────────
    #
    # POST /charges
    #   Headers: Authorization: Bearer <key>, X-Request-Id: <caller's reference>
    #   Body:    amount_minor, currency, payment_method_token, capture (bool)
    #   200:     { id, reference, status: authorized|declined, code?, ... }
    post "/charges" do
      authenticate!
      reference = request.env["HTTP_X_REQUEST_ID"].to_s
      error!(400, "missing_request_id", "X-Request-Id header is required") if reference.empty?

      body = body_json
      amount = body["amount_minor"]
      currency = body["currency"].to_s
      error!(422, "invalid_amount", "amount_minor must be a positive integer") unless amount.is_a?(Integer) && amount.positive?
      error!(422, "unsupported_currency", "Nordpay supports #{CURRENCIES.join(', ')}") unless CURRENCIES.include?(currency)

      charge = nil
      store.sync do
        charge = store.find_or_create(reference)
        charge.attempts += 1

        # Idempotency: a repeat X-Request-Id returns the original charge untouched.
        if charge.status.nil?
          charge.amount_minor = amount
          charge.currency = currency
          if inject?("decline")
            charge.status = "declined"
            charge.code = "insufficient_funds"
          else
            charge.status = "authorized"
            charge.captured_minor = amount if body["capture"] == true
          end
        end
      end

      # Webhook for the outcome — only on the first attempt, so a retried
      # request does not re-announce. The webhook belongs to the CHARGE, not to
      # this HTTP response: it fires even when the response then 500s or times
      # out. That is the "timeout but the charge succeeded" scenario.
      if charge.attempts == 1
        emit!(charge, charge.status == "declined" ? "charge.declined" : "charge.authorized", charge.created_at)
      end

      # Flaky: the charge IS recorded, but the first attempt fails at the transport layer.
      if charge.attempts == 1 && inject?("flaky_500")
        error!(500, "internal_error", "try again")
      end

      # Timeout: the charge IS recorded (above), then we hang past the client's deadline.
      sleep(config.fetch("timeout_seconds", 5).to_f) if inject?("timeout")

      if inject?("duplicate")
        # Same charge twice in one body. The client must dedupe on reference.
        json!({ charges: [charge.to_h, charge.to_h] })
      else
        json!(charge.to_h)
      end
    end

    # GET /charges/:reference — the read that resolves an `unknown` payment.
    get "/charges/:reference" do
      authenticate!
      charge = store.find(params[:reference])
      error!(404, "not_found", "no charge with reference #{params[:reference]}") unless charge&.status
      json!(charge.to_h)
    end

    # POST /charges/:reference/capture — body: amount_minor (optional, defaults to full)
    post "/charges/:reference/capture" do
      authenticate!
      charge = store.find(params[:reference])
      error!(404, "not_found", "no such charge") unless charge&.status
      error!(409, "not_authorized", "charge is #{charge.status}") unless charge.status == "authorized"

      amount = body_json.fetch("amount_minor", charge.amount_minor - charge.captured_minor)
      error!(422, "invalid_amount", "capture exceeds authorized") if charge.captured_minor + amount > charge.amount_minor

      captured_at = Time.now
      store.sync do
        charge.captured_minor += amount
        charge.status = "captured" if charge.captured_minor == charge.amount_minor
      end

      # charge.captured, honestly timestamped. Out-of-order injection resends
      # the EARLIER charge.authorized event after it — same ids as a real PSP
      # replaying an older event, so the receiver must order by created_at.
      emit!(charge, "charge.captured", captured_at)
      if inject?("webhook_out_of_order")
        stale = charge.to_h.merge(status: "authorized", captured_minor: 0)
        deliver({ id: "evt_#{SecureRandom.hex(8)}", type: "charge.authorized", created_at: charge.created_at.utc.iso8601(3), data: stale },
                delay: config.fetch("webhook_delay_seconds", 0.2).to_f + 0.1)
      end
      json!(charge.to_h)
    end

    # POST /charges/:reference/void — release an authorization. Idempotent.
    post "/charges/:reference/void" do
      authenticate!
      charge = store.find(params[:reference])
      error!(404, "not_found", "no such charge") unless charge&.status
      error!(409, "not_voidable", "charge is #{charge.status}") unless %w[authorized canceled].include?(charge.status)

      store.sync { charge.status = "canceled" }
      json!(charge.to_h)
    end

    # POST /charges/:reference/refunds — body: amount_minor. Partial allowed.
    #   Headers: X-Request-Id: <caller's refund reference> (idempotent)
    #   200: { id, reference, charge_reference, status: succeeded|failed, amount_minor, created_at }
    post "/charges/:reference/refunds" do
      authenticate!
      charge = store.find(params[:reference])
      error!(404, "not_found", "no such charge") unless charge&.status
      ref = request.env["HTTP_X_REQUEST_ID"].to_s
      error!(400, "missing_request_id", "X-Request-Id header is required") if ref.empty?

      refund = nil
      store.sync do
        refund = store.refunds[ref]
        unless refund
          amount = body_json.fetch("amount_minor", charge.captured_minor)
          refunded = store.refunds.values.select { |r| r.charge_reference == charge.reference && r.status == "succeeded" }
                          .sum(&:amount_minor)
          status, code =
            if charge.captured_minor.zero? then ["failed", "not_captured"]
            elsif refunded + amount > charge.captured_minor then ["failed", "exceeds_captured"]
            else ["succeeded", nil]
            end
          refund = store.refunds[ref] = Store::Refund.new(
            id: "re_#{SecureRandom.hex(8)}", reference: ref, charge_reference: charge.reference,
            status: status, code: code, amount_minor: amount, created_at: Time.now
          )
        end
      end

      sleep(config.fetch("timeout_seconds", 5).to_f) if inject?("timeout")
      json!(refund.to_h)
    end

    get "/refunds/:reference" do
      authenticate!
      refund = store.refunds[params[:reference]]
      error!(404, "not_found", "no refund with reference #{params[:reference]}") unless refund
      json!(refund.to_h)
    end

    error do
      json!({ error: { code: "internal_error", message: env["sinatra.error"].message } }, status: 500)
    end
  end
end
