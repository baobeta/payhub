# typed: true
# frozen_string_literal: true

# The list filters, shared by GET /v1/payments and the dashboard list and
# export. Raises ArgumentError on a malformed date; callers turn it into 400.
module PaymentFilters
  def self.apply(scope, params)
    scope = scope.where(state: params[:state]) if params[:state].present?
    scope = scope.where(currency: params[:currency]) if params[:currency].present?
    scope = scope.where(created_at: Time.iso8601(params[:created_after])..) if params[:created_after].present?
    scope = scope.where(created_at: ..Time.iso8601(params[:created_before])) if params[:created_before].present?
    scope
  end
end
