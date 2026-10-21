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

    scheme, credentials = authorization.to_s.split(" ", 2)
    return false unless scheme&.casecmp?("Bearer") && credentials

    ActiveSupport::SecurityUtils.secure_compare(credentials.strip, token.strip)
  end

  # Called at boot (config/initializers/metrics_token.rb). A missing token is
  # not worth refusing to boot over, but every scrape will be refused.
  sig { params(token: T.nilable(String)).void }
  def self.warn_if_unset_in_production(token: ENV["METRICS_TOKEN"])
    return unless Rails.env.production? && token.blank?

    Rails.logger.warn("METRICS_TOKEN is not set: /metrics will refuse every scrape with 401")
  end
end
