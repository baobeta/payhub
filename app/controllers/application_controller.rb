# typed: true
# frozen_string_literal: true

class ApplicationController < ActionController::API
  extend T::Sig

  before_action do
    T.bind(self, ApplicationController)
    Current.request_id = request.request_id
  end

  private

  # The keys every request log line carries (see config/initializers/lograge.rb).
  # Subclasses set @log_merchant_id / @log_payment_id / @log_psp_name as they
  # learn them; nil keys are dropped by the formatter.
  sig { returns(T::Hash[Symbol, T.untyped]) }
  def log_payload
    {
      request_id: request.request_id,
      merchant_id: @log_merchant_id,
      payment_id: @log_payment_id || params[:id].presence || params[:payment_id].presence,
      psp_name: @log_psp_name || params[:psp_name].presence
    }
  end
end
