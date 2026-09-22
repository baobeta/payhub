module ApiHelpers
  # A merchant plus the raw bearer key that authenticates as them.
  def create_merchant_with_key(**attrs)
    Merchant.create_with_api_key!({ name: "Acme", default_currency: "EUR" }.merge(attrs))
  end

  def auth_headers(raw_key, idempotency_key: SecureRandom.uuid)
    {
      "Authorization" => "Bearer #{raw_key}",
      "Idempotency-Key" => idempotency_key,
      "Content-Type" => "application/json",
      "Accept" => "application/json"
    }
  end

  def json_body = JSON.parse(response.body)
end

RSpec.configure do |config|
  config.include ApiHelpers, type: :request
end
