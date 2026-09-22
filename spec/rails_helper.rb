require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "webmock/rspec"

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.fixture_paths = [Rails.root.join("spec/fixtures")]
  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
  config.include ActiveJob::TestHelper # perform_enqueued_jobs in property and request specs

  # Transactional fixtures roll back after each example. Specs tagged
  # `concurrency: true` use real threads + real connections, which cannot see
  # an uncommitted transaction, so they run without and clean up manually.
  config.use_transactional_fixtures = true
  config.around(:each, :concurrency) do |example|
    self.use_transactional_tests = false
    example.run
    ActiveRecord::Base.connection.execute(
      "TRUNCATE merchants, payments, payment_transitions, refunds, idempotency_keys, " \
      "ledger_accounts, ledger_entries, inbound_events, outbound_events, outbound_delivery_attempts, fx_rates CASCADE"
    )
  end

  config.filter_rails_from_backtrace!
  config.order = :random
  Kernel.srand config.seed
end
