# frozen_string_literal: true

# Production without METRICS_TOKEN boots, but /metrics refuses every scrape;
# say so once at boot rather than leaving it to a silent 401 on the scraper.
Rails.application.config.after_initialize do
  MetricsAuth.warn_if_unset_in_production
end
