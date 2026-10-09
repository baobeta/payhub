# frozen_string_literal: true

# The one rule, proven live. Drives the real HTTP API through a hostile
# Nordpay simulator and checks the books against the PSP's own records.
#
#   docker compose exec web bin/rails chaos:run          # 40 payments
#   docker compose exec web bin/rails "chaos:run[100]"
#
# Exits 1 if any invariant breaks. Restores the simulator's config afterwards.
# The behaviour lives in app/lib/chaos_run.rb so the demo's chaos button can
# drive it from a job (D-04).
namespace :chaos do
  desc "Run a chaos scenario against the Nordpay simulator and verify no double charge / over-refund"
  task :run, [:payments] => :environment do |_t, args|
    result = ChaosRun.new(payments: (args[:payments] || 40).to_i).call
    exit(1) unless result[:passed]
  end
end
