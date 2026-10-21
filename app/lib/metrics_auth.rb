# typed: strict
# frozen_string_literal: true

# Who may scrape metrics. Scrapers present `Authorization: Bearer $METRICS_TOKEN`.
# Without a token configured, development and test stay open; production is
# closed, not open: an exposed /metrics leaks payment volumes.
module MetricsAuth
  extend T::Sig

  sig { params(authorization: T.nilable(String), token: T.nilable(String)).returns(T::Boolean) }
  def self.authorized?(authorization, token: ENV["METRICS_TOKEN"])
    return !Rails.env.production? if token.blank?

    header = authorization.to_s
    return false unless header.start_with?("Bearer ")

    ActiveSupport::SecurityUtils.secure_compare(header.delete_prefix("Bearer "), token)
  end
end
