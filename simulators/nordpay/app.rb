# frozen_string_literal: true

require "sinatra/base"
require "json"
require "yaml"
require "securerandom"
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

    def initialize
      @charges = {}
      @mutex = Mutex.new
    end

    def sync(&) = @mutex.synchronize(&)
    def find(reference) = @charges[reference]
    def all = @charges.values
    def reset! = @charges.clear

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

    set :store, Store.new
    set :failure, YAML.safe_load_file(File.expand_path("failure_config.yml", __dir__))
    set :show_exceptions, false
    set :logging, true
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
      def inject?(behaviour)
        forced = request.env["HTTP_X_SIM_FORCE"].to_s.split(",").map(&:strip)
        return true if forced.include?(behaviour)
        return false if forced.any? # forcing one behaviour disables the random others

        rate = config.fetch("#{behaviour}_rate", 0).to_f
        rate.positive? && rand < rate
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

      store.sync do
        charge.captured_minor += amount
        charge.status = "captured" if charge.captured_minor == charge.amount_minor
      end
      json!(charge.to_h)
    end

    error do
      json!({ error: { code: "internal_error", message: env["sinatra.error"].message } }, status: 500)
    end
  end
end
