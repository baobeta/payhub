# typed: false
# frozen_string_literal: true

# A real PspAdapter subclass (so Sorbet's runtime sigs accept it) that answers
# from a script. Each call to authorize/fetch shifts the next scripted answer:
# a Result to return, or an exception class/instance to raise.
#
#   adapter = FakePspAdapter.new
#   adapter.script(:authorize, PspAdapter::TimedOut, result(:authorized))
#   adapter.script(:fetch, result(:not_found))
class FakePspAdapter < PspAdapter
  attr_reader :calls, :called_at

  def initialize(name: "nordpay", currencies: %w[EUR GBP USD], partial_refund: true, separate_auth: true)
    super()
    @name = name
    @currencies = currencies
    @partial_refund = partial_refund
    @separate_auth = separate_auth
    @scripts = Hash.new { |h, k| h[k] = [] }
    @calls = Hash.new { |h, k| h[k] = [] }
    @called_at = Hash.new { |h, k| h[k] = [] }
  end

  # The moment the PSP "received" the most recent call of `method`. A realistic
  # PSP timestamp for a charge is this + a few ms: after we sent it, before we
  # gave up. Use it to build results that mirror what a real PSP would report.
  def received_at(method) = @called_at[method].last

  def script(method, *answers)
    @scripts[method].concat(answers)
    self
  end

  def name = @name
  def currencies = @currencies
  def supports_partial_refund? = @partial_refund
  def separate_authorize_and_capture? = @separate_auth

  def authorize(payment) = answer(:authorize, payment)
  def fetch(psp_reference) = answer(:fetch, psp_reference)
  def capture(payment, amount_minor) = answer(:capture, [payment, amount_minor])
  def cancel(payment) = answer(:cancel, payment)
  def refund(refund) = answer(:refund, refund)
  def fetch_refund(psp_reference) = answer(:fetch_refund, psp_reference)
  def verify_webhook(raw_body, headers) = answer(:verify_webhook, [raw_body, headers])
  def parse_webhook(payload) = answer(:parse_webhook, payload)
  def settlement_report(date) = answer(:settlement_report, date)

  private

  def answer(method, arg)
    @calls[method] << arg
    @called_at[method] << Time.current
    next_answer = @scripts[method].shift or raise "FakePspAdapter: no scripted answer left for #{method}"
    next_answer = next_answer.call if next_answer.is_a?(Proc) # lazy: built at call time
    case next_answer
    when Class then raise next_answer, "scripted #{method} failure"
    when Exception then raise next_answer
    else next_answer
    end
  end
end
