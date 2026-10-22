require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Production skips sorbet-runtime's per-call sig checks (`srb tc` in CI has
# proven the types). Sorbet only accepts this before any sig is evaluated, and
# payhub_config.rb below has one, so it cannot wait for an initializer.
T::Configuration.default_checked_level = :never if Rails.env.production?

# Plain Ruby, needed while this file runs, so it is required here rather than
# autoloaded (and ignored by Zeitwerk below).
require_relative "../lib/payhub_config"
require_relative "../lib/test_database"

# The test env never uses a DATABASE_URL or MIGRATION_DATABASE_URL that names
# another database (Compose points both at payhub_development): it falls back
# to config/database.yml, PGHOST/PGPORT and TEST_DATABASE, i.e. Postgres
# itself. Rails has set RAILS_ENV by now for every entry point (bin/rails -e,
# rake, rspec's rails_helper), and reads the URLs only when it initializes.
TestDatabase.drop_foreign_urls! if Rails.env.test?

module Payhub
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks payhub_config.rb test_database.rb])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # The UI (Web::BaseController) needs cookies and a session for CSRF tokens.
    # /v1 never reads the session, so it never sets a cookie. Auth cookies are
    # separate, path-scoped signed cookies per area (design §1).
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::ContentSecurityPolicy::Middleware # see config/initializers/content_security_policy.rb
    config.middleware.use ActionDispatch::Session::CookieStore, key: "_payhub_web", same_site: :strict,
                                                                secure: Rails.env.production?

    # UUID v7 primary keys, generated in Postgres (see the first migration).
    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
    end

    # schema.rb cannot represent the uuid_generate_v7() function, CHECK
    # constraints, or partial indexes faithfully. structure.sql can.
    config.active_record.schema_format = :sql

    config.active_job.queue_adapter = :sidekiq

    # The public demo needs no login, so production keeps it off unless
    # DEMO_ENABLED=true.
    config.x.demo_enabled = PayhubConfig.demo_enabled_default(Rails.env.to_s, ENV["DEMO_ENABLED"])
  end
end
