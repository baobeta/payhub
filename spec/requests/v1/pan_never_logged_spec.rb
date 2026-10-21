require "rails_helper"

# PCI: the service takes a token, never a card number. A card number sent as
# the token is refused (PCI DSS 3.3/3.4), and this proves that even if a
# client sends a PAN-shaped string — in the token field, in metadata, in an
# unknown field — it never reaches the log, a stored response or any table.
# Two layers for the log: Rails' filter_parameters, and lograge not logging
# params at all.
RSpec.describe "A PAN never reaches the log", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key }
  let(:key) { merchant_and_key.last }
  let(:pan) { "4242424242424242" } # Luhn-valid test PAN
  let(:cvv) { "737" }

  # Capture EVERYTHING Rails logs during the request.
  def capture_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = Logger::DEBUG
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end

  # Every text column of every table, as one string per row.
  def rows_containing(needle)
    connection = ActiveRecord::Base.connection
    connection.tables.sum do |table|
      connection.select_value(
        "SELECT count(*) FROM #{connection.quote_table_name(table)} t WHERE t::text LIKE #{connection.quote("%#{needle}%")}"
      ).to_i
    end
  end

  it "TC-A14-1: refuses a card number sent as the token, spaced, dashed or plain, without echoing it" do
    ["4242 4242 4242 4242", "4242-4242-4242-4242", pan].each do |card|
      expect do
        post "/v1/payments", params: { amount_minor: 2500, currency: "EUR", payment_method_token: card }.to_json,
                             headers: auth_headers(key)
      end.not_to change(Payment, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body.dig("error", "details", "payment_method_token")).to eq(["looks like a card number; send a token"])
      expect(response.body).not_to include(pan, card)
    end
  end

  it "TC-A14-1: a PAN or CVV sent as the token, in metadata, or in a stray field reaches no log, response or table" do
    log = capture_log do
      post "/v1/payments",
           params: { amount_minor: 2500, currency: "EUR", payment_method_token: "4242 4242 4242 4242",
                     metadata: { card_number: pan, cvv: cvv, note: "cust #{pan}" }, number: pan }.to_json,
           headers: auth_headers(key)
      post "/v1/payments", params: { amount_minor: -1, payment_method_token: pan, cvv: cvv }.to_json,
                           headers: auth_headers(key)
      expect(response).to have_http_status(:unprocessable_content)
    end

    expect(log).not_to include(pan)
    # A CVV is three digits, and every log line carries random hex (trace and
    # span ids) and decimals (timestamps like 04:22:27.737Z, durations) that
    # contain any three digits sooner or later. A leaked CVV stands alone
    # ("cvv":"737", cvv=737); inside a run of hex or after a decimal point it
    # is chance.
    expect(log).not_to match(/(?<![[:xdigit:].])#{cvv}(?![[:xdigit:].])/)
    expect(log).not_to match(/\b\d{13,19}\b/) # no PAN-shaped number of any kind
    # idempotency_keys.response_body included: every table, every column.
    expect(rows_containing(pan) + rows_containing("4242 4242")).to eq(0)
  end

  it "TC-A14-2: ordinary tokens still pass, including a 16-digit number that fails Luhn" do
    %w[tok_visa wallet_abc123 4242424242424241].each do |token|
      post "/v1/payments", params: { amount_minor: 2500, currency: "EUR", payment_method_token: token }.to_json,
                           headers: auth_headers(key)
      expect(response).to have_http_status(:accepted), token
    end
  end

  it "does not log the bearer key or a webhook signature" do
    sig = "t=1,v1=#{'a' * 64}"
    log = capture_log do
      post "/v1/webhooks/kiripay", params: "{}", headers: { "Content-Type" => "application/json", "X-Kiripay-Signature" => sig }
      get "/v1/balance", headers: auth_headers(key)
    end

    expect(log).not_to include(key)
    expect(log).not_to include("a" * 64)
  end

  it "filters the listed parameter names when Rails renders params (defence in depth)" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
                                             .filter("card" => pan, "cvv" => cvv, "card_number" => pan,
                                                     "payment_method_token" => "tok_x", "authorization" => "Bearer x",
                                                     "signature" => "s", "amount_minor" => 2500)
    expect(filtered.values_at("card", "cvv", "card_number", "payment_method_token", "authorization", "signature").uniq)
      .to eq(["[FILTERED]"])
    expect(filtered["amount_minor"]).to eq(2500)
  end
end
