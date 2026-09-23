# typed: strict
# frozen_string_literal: true

# POST /v1/payments, the synchronous half. Reserves the row and the
# psp_reference, snapshots the FX rate, enqueues the PSP call, and returns.
# No network I/O happens here — that is what lets the API answer 202 in
# milliseconds regardless of PSP latency (DECISIONS #8).
class CreatePayment
  extend T::Sig

  class Params < T::Struct
    const :amount_minor, Integer
    const :currency, String
    const :payment_method_token, String
    const :capture, T::Boolean, default: false
    const :metadata, T::Hash[String, T.untyped], default: {}
  end

  sig { params(merchant: Merchant, params: Params).returns(Payment) }
  def self.call(merchant, params) = new(merchant, params).call

  sig { params(merchant: Merchant, params: Params).void }
  def initialize(merchant, params)
    @merchant = merchant
    @params = params
  end

  sig { returns(Payment) }
  def call
    psp_name = PspRouter.name_for(@params.currency)
    fx_rate = FxRate.latest!(@params.currency, @merchant.default_currency)

    Tracing.in_span("payhub.payment.create", attributes: {
      "payhub.merchant_id" => @merchant.id,
      "payhub.psp_name" => psp_name,
      "payhub.operation" => "create_payment"
    }) do |span|
      payment = Payment.transaction do
        Payment.create!(
          merchant: @merchant,
          amount_minor: @params.amount_minor,
          currency: @params.currency,
          merchant_currency: @merchant.default_currency,
          fx_rate: fx_rate,
          psp_name: psp_name,
          # Reserved BEFORE any network call (DECISIONS #2).
          psp_reference: Payment.generate_psp_reference,
          payment_method_token: @params.payment_method_token,
          capture_on_authorize: @params.capture,
          metadata: @params.metadata
        )
      end

      span.set_attribute("payhub.payment_id", payment.id) if span.respond_to?(:set_attribute)
      # Enqueued after commit so the job can never run against a row that was
      # rolled back. Rails' `perform_later` inside a transaction is enqueued at
      # commit time only with the async adapter's enqueue_after_transaction_commit;
      # keeping it outside the transaction is explicit and adapter-independent.
      AuthorizePaymentJob.perform_later(payment.id)
      Metrics.increment(:payments_created, psp: psp_name, currency: @params.currency)
      payment
    end
  end
end
