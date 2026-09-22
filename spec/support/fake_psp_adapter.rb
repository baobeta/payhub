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
  attr_reader :calls

  def initialize(name: "nordpay", currencies: %w[EUR GBP USD], partial_refund: true, separate_auth: true)
    super()
    @name = name
    @currencies = currencies
    @partial_refund = partial_refund
    @separate_auth = separate_auth
    @scripts = Hash.new { |h, k| h[k] = [] }
    @calls = Hash.new { |h, k| h[k] = [] }
  end

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

  private

  def answer(method, arg)
    @calls[method] << arg
    next_answer = @scripts[method].shift or raise "FakePspAdapter: no scripted answer left for #{method}"
    case next_answer
    when Class then raise next_answer, "scripted #{method} failure"
    when Exception then raise next_answer
    else next_answer
    end
  end
end
