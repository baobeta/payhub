require "rails_helper"

# PCI: the service takes a token, never a card number. This proves that even
# if a client sends a PAN-shaped string — in the token field, in metadata, in
# an unknown field — it never reaches the log. Two layers: Rails'
# filter_parameters, and lograge not logging params at all.
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

  it "does not log a PAN or CVV sent as the token, in metadata, or in a stray field, on success or on 422" do
    log = capture_log do
      post "/v1/payments",
           params: { amount_minor: 2500, currency: "EUR", payment_method_token: pan,
                     metadata: { card_number: pan, cvv: cvv, note: "cust #{pan}" }, number: pan }.to_json,
           headers: auth_headers(key)
      expect(response).to have_http_status(:accepted)

      post "/v1/payments", params: { amount_minor: -1, payment_method_token: pan, cvv: cvv }.to_json,
                           headers: auth_headers(key)
      expect(response).to have_http_status(:unprocessable_content)
    end

    expect(log).not_to include(pan)
    # A CVV is three digits, and every log line carries random hex (trace and
    # span ids) that contains any three digits sooner or later. A leaked CVV
    # stands alone ("cvv":"737", cvv=737); inside a run of hex it is chance.
    expect(log).not_to match(/(?<![[:xdigit:]])#{cvv}(?![[:xdigit:]])/)
    expect(log).not_to match(/\b\d{13,19}\b/) # no PAN-shaped number of any kind
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
